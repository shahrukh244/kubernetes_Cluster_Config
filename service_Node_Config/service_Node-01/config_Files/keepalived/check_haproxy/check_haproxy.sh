#!/bin/bash
# HAProxy Load Balancer Health Check - Enhanced Version

set -o errexit
set -o nounset
set -o pipefail

# ========== CONFIGURATION ==========
readonly SERVICE_NAME="haproxy"
readonly LOG_FILE="/var/log/check_haproxy.log"
readonly MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB max log size
readonly MAX_RETRIES=2
readonly CHECK_TIMEOUT=5                  # seconds
readonly STATS_SOCKET="/var/run/haproxy.sock"  # HAProxy stats socket
readonly STATS_PORT="1936"                # HAProxy stats port (if enabled)
readonly STATS_URI="/stats"               # HAProxy stats URI
readonly EXPECTED_PORTS="80 443"          # Ports HAProxy should be listening on
readonly HEALTH_CHECK_PORT="80"           # Port for HTTP health check
readonly HEALTH_CHECK_HOST="localhost"    # Host for health check
readonly MAX_BACKEND_FAILURES=0           # Max allowed backend failures
# ===================================

# ========== FUNCTIONS ==========
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Console output
    case "${level}" in
        "ERROR"|"CRITICAL")
            echo "[${timestamp}] ${level}: ${message}" >&2
            ;;
        *)
            echo "[${timestamp}] ${level}: ${message}" >&1
            ;;
    esac
    
    # Log to file with rotation
    log_to_file "${timestamp}" "${level}" "${message}"
}

log_to_file() {
    local timestamp="$1"
    local level="$2"
    local message="$3"
    
    # Check log file size and rotate if needed
    if [ -f "${LOG_FILE}" ] && [ "$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)" -gt ${MAX_LOG_SIZE} ]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old" 2>/dev/null || true
    fi
    
    # Write to log file
    echo "[${timestamp}] ${level}: ${message}" >> "${LOG_FILE}"
}

check_service_active() {
    local service_name="$1"
    
    # Use timeout to prevent hanging
    if timeout ${CHECK_TIMEOUT} systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        log_message "DEBUG" "Service '${service_name}' is active"
        return 0
    else
        log_message "DEBUG" "Service '${service_name}' is not active"
        return 1
    fi
}

check_haproxy_process() {
    # Check for HAProxy process
    if pgrep -x "haproxy" >/dev/null 2>&1; then
        # Get process details
        local pids
        pids=$(pgrep -x "haproxy" | tr '\n' ' ')
        local process_count
        process_count=$(echo "${pids}" | wc -w)
        
        log_message "INFO" "HAProxy process running - PIDs: ${pids} (${process_count} processes)"
        
        # Check process states
        local master_found=false
        local worker_count=0
        
        for pid in ${pids}; do
            if [ -d "/proc/${pid}" ]; then
                local process_cmd
                process_cmd=$(cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' ' ' || echo "unknown")
                local process_state
                process_state=$(cat "/proc/${pid}/status" 2>/dev/null | grep "^State:" | cut -f2 || echo "unknown")
                
                log_message "DEBUG" "Process ${pid} state: ${process_state}, cmd: ${process_cmd:0:100}"
                
                # Check if this is master or worker
                if echo "${process_cmd}" | grep -q "master"; then
                    master_found=true
                    log_message "DEBUG" "Process ${pid} is master process"
                elif echo "${process_cmd}" | grep -q "worker"; then
                    worker_count=$((worker_count + 1))
                    log_message "DEBUG" "Process ${pid} is worker process"
                fi
            fi
        done
        
        if [ "${master_found}" = true ] && [ ${worker_count} -gt 0 ]; then
            log_message "INFO" "HAProxy master and ${worker_count} worker(s) running"
            return 0
        else
            log_message "WARNING" "HAProxy processes found but master/worker configuration unexpected"
            return 1
        fi
    else
        log_message "WARNING" "No HAProxy process found"
        return 1
    fi
}

check_listening_ports() {
    # Check if HAProxy is listening on expected ports
    local port_issues=0
    local haproxy_ports
    haproxy_ports=$(ss -ltn 2>/dev/null | awk '/haproxy/ {print $4}' | awk -F: '{print $NF}' | sort -u)
    
    log_message "DEBUG" "HAProxy listening ports: ${haproxy_ports:-none}"
    
    # Check expected ports
    for port in ${EXPECTED_PORTS}; do
        if echo "${haproxy_ports}" | grep -q "^${port}$"; then
            log_message "DEBUG" "Port ${port} is listening"
        else
            log_message "WARNING" "Port ${port} is not listening (expected)"
            port_issues=$((port_issues + 1))
        fi
    done
    
    # Check if any ports are listening at all
    if [ -z "${haproxy_ports}" ]; then
        log_message "CRITICAL" "HAProxy is not listening on any ports"
        port_issues=$((port_issues + 10))  # Critical failure
    fi
    
    return ${port_issues}
}

check_haproxy_config() {
    # Check HAProxy configuration syntax
    log_message "DEBUG" "Checking HAProxy configuration..."
    
    if command -v haproxy >/dev/null 2>&1; then
        # Try to get config file path
        local config_file
        config_file=$(find /etc/haproxy -name "haproxy.cfg" 2>/dev/null | head -1)
        
        if [ -z "${config_file}" ]; then
            config_file="/etc/haproxy/haproxy.cfg"
        fi
        
        if [ -f "${config_file}" ]; then
            log_message "INFO" "Checking config file: ${config_file}"
            
            # Test configuration syntax
            if haproxy -c -f "${config_file}" >/tmp/haproxy_test.log 2>&1; then
                log_message "INFO" "HAProxy configuration syntax is valid"
                
                # Check for warnings
                if grep -i "warning" /tmp/haproxy_test.log >/dev/null 2>&1; then
                    log_message "WARNING" "Configuration warnings found:"
                    grep -i "warning" /tmp/haproxy_test.log | while read -r line; do
                        log_message "WARNING" "  ${line}"
                    done
                fi
                return 0
            else
                log_message "CRITICAL" "HAProxy configuration syntax error"
                cat /tmp/haproxy_test.log >> "${LOG_FILE}" 2>/dev/null || true
                return 1
            fi
        else
            log_message "WARNING" "HAProxy config file not found: ${config_file}"
            return 0  # Not a critical error if service is running
        fi
    else
        log_message "WARNING" "haproxy command not found, skipping config check"
        return 0
    fi
}

check_stats_socket() {
    # Check HAProxy stats socket
    log_message "DEBUG" "Checking HAProxy stats socket..."
    
    # Try different socket locations
    local socket_found=false
    local socket_locations=(
        "${STATS_SOCKET}"
        "/var/run/haproxy/admin.sock"
        "/run/haproxy.sock"
        "/run/haproxy/admin.sock"
    )
    
    for socket in "${socket_locations[@]}"; do
        if [ -S "${socket}" ]; then
            log_message "INFO" "Found stats socket: ${socket}"
            
            # Test socket communication
            if echo "show info" | socat stdio "${socket}" >/dev/null 2>&1; then
                log_message "INFO" "Stats socket is responsive"
                return 0
            else
                log_message "WARNING" "Stats socket exists but not responsive"
                return 1
            fi
        fi
    done
    
    log_message "DEBUG" "No stats socket found (may be disabled)"
    return 0  # Not a critical error
}

check_stats_http() {
    # Check HAProxy stats via HTTP
    log_message "DEBUG" "Checking HAProxy HTTP stats..."
    
    # Try to get stats port from config
    local stats_port="${STATS_PORT}"
    
    # Check if stats is enabled on expected ports
    if command -v curl >/dev/null 2>&1; then
        # Try localhost on stats port
        if timeout 3 curl -f -s "http://${HEALTH_CHECK_HOST}:${stats_port}${STATS_URI}" >/dev/null 2>&1; then
            log_message "INFO" "HTTP stats page is accessible on port ${stats_port}"
            
            # Get stats data
            local stats_output
            stats_output=$(timeout 3 curl -s "http://${HEALTH_CHECK_HOST}:${stats_port}${STATS_URI};csv" 2>/dev/null || echo "")
            
            if [ -n "${stats_output}" ]; then
                log_message "DEBUG" "Stats CSV data available"
                echo "${stats_output}" > /tmp/haproxy_stats.csv 2>/dev/null || true
                return 0
            else
                log_message "INFO" "Stats page accessible but CSV format not available"
                return 0
            fi
        else
            log_message "DEBUG" "HTTP stats not accessible on port ${stats_port} (may be disabled)"
            return 0  # Not a critical error
        fi
    else
        log_message "DEBUG" "curl not available, skipping HTTP stats check"
        return 0
    fi
}

check_backend_health() {
    # Check backend health using stats
    log_message "DEBUG" "Checking backend health..."
    
    # Try socket first, then HTTP
    local stats_data=""
    
    # Try to get stats from socket
    for socket in "${STATS_SOCKET}" "/var/run/haproxy/admin.sock" "/run/haproxy.sock"; do
        if [ -S "${socket}" ]; then
            if echo "show stat" | socat stdio "${socket}" 2>/dev/null > /tmp/haproxy_stats.csv; then
                stats_data=$(cat /tmp/haproxy_stats.csv)
                break
            fi
        fi
    done
    
    # If no socket, try HTTP
    if [ -z "${stats_data}" ] && command -v curl >/dev/null 2>&1; then
        stats_data=$(timeout 3 curl -s "http://${HEALTH_CHECK_HOST}:${STATS_PORT}${STATS_URI};csv" 2>/dev/null || echo "")
    fi
    
    if [ -n "${stats_data}" ]; then
        # Parse CSV stats
        local backend_failures=0
        local backend_count=0
        
        # Skip header line
        echo "${stats_data}" | tail -n +2 | while IFS=, read -r pxname svname qcur qmax scur smax slim stot bin bout dreq dcon ereq econ eresp wretr wredis status weight act bck chkdown lastchg downtime qlimit pid iid sid throttle lbtot tracked type rate rate_lim rate_max check_status check_code check_duration hrsp_1xx hrsp_2xx hrsp_3xx hrsp_4xx hrsp_5xx hrsp_other hanafail req_rate req_rate_max req_tot cli_abrt srv_abrt; do
            # Skip empty lines and frontend rows
            [ -z "${pxname}" ] && continue
            [ "${svname}" = "BACKEND" ] || [ "${svname}" = "FRONTEND" ] && continue
            
            backend_count=$((backend_count + 1))
            
            # Check status
            if [ "${status}" != "UP" ] && [ "${status}" != "OPEN" ]; then
                log_message "WARNING" "Backend ${pxname}/${svname} status: ${status}"
                backend_failures=$((backend_failures + 1))
            fi
            
            # Check health check failures
            if [ "${check_status}" != "L4OK" ] && [ "${check_status}" != "L7OK" ] && [ "${check_status}" != "" ]; then
                log_message "WARNING" "Backend ${pxname}/${svname} check status: ${check_status}"
            fi
        done
        
        if [ ${backend_failures} -gt ${MAX_BACKEND_FAILURES} ]; then
            log_message "WARNING" "Too many backend failures: ${backend_failures}/${backend_count}"
            return 1
        elif [ ${backend_count} -eq 0 ]; then
            log_message "INFO" "No backends configured or stats not available"
        else
            log_message "INFO" "Backend health: ${backend_failures}/${backend_count} failures"
        fi
        return 0
    else
        log_message "DEBUG" "No stats data available for backend health check"
        return 0  # Not a critical error
    fi
}

check_http_health() {
    # Simple HTTP health check through HAProxy
    log_message "DEBUG" "Performing HTTP health check..."
    
    if command -v curl >/dev/null 2>&1; then
        # Try to connect through HAProxy
        if timeout ${CHECK_TIMEOUT} curl -f -s -o /dev/null -w "HTTP %{http_code}" \
            "http://${HEALTH_CHECK_HOST}:${HEALTH_CHECK_PORT}" >/tmp/curl_output.log 2>&1; then
            local http_code
            http_code=$(grep -o "HTTP [0-9][0-9][0-9]" /tmp/curl_output.log | awk '{print $2}')
            
            if [ "${http_code}" = "200" ] || [ "${http_code}" = "301" ] || [ "${http_code}" = "302" ]; then
                log_message "INFO" "HTTP health check passed (HTTP ${http_code})"
                return 0
            else
                log_message "WARNING" "HTTP health check returned non-OK status: HTTP ${http_code}"
                return 1
            fi
        else
            log_message "WARNING" "HTTP health check failed (connection refused/timeout)"
            return 1
        fi
    else
        log_message "DEBUG" "curl not available, skipping HTTP health check"
        return 0
    fi
}

check_pid_file() {
    # Check HAProxy PID file
    local pid_file
    pid_file=$(find /var/run -name "haproxy*.pid" 2>/dev/null | head -1)
    
    if [ -z "${pid_file}" ]; then
        # Try common locations
        pid_file="/var/run/haproxy.pid"
    fi
    
    if [ -f "${pid_file}" ]; then
        local pid
        pid=$(cat "${pid_file}" 2>/dev/null)
        
        if [ -n "${pid}" ] && [ -d "/proc/${pid}" ]; then
            log_message "INFO" "PID file valid: ${pid_file} (PID: ${pid})"
            return 0
        else
            log_message "WARNING" "PID file exists but process ${pid} not running: ${pid_file}"
            return 1
        fi
    else
        log_message "DEBUG" "No PID file found (may be normal for this installation)"
        return 0
    fi
}

get_service_status() {
    local service_name="$1"
    
    log_message "DEBUG" "Getting status for service: ${service_name}"
    
    # Capture service status
    if systemctl status "${service_name}" --no-pager >/tmp/haproxy_status.log 2>&1; then
        # Extract relevant status info
        local active_line
        active_line=$(grep -i "active:" /tmp/haproxy_status.log | head -1)
        log_message "INFO" "Service status: ${active_line}"
        
        # Check for recent errors
        local errors
        errors=$(grep -i "error\|failed\|failed to\|unable to" /tmp/haproxy_status.log | tail -3)
        if [ -n "${errors}" ]; then
            log_message "WARNING" "Service logs contain errors:"
            echo "${errors}" | while read -r line; do
                log_message "WARNING" "  ${line}"
            done
        fi
    else
        log_message "WARNING" "Failed to get service status"
    fi
}

perform_health_check() {
    local retry=0
    
    log_message "INFO" "Starting HAProxy load balancer health check"
    
    # Main check loop with retries
    while [ ${retry} -le ${MAX_RETRIES} ]; do
        if [ ${retry} -gt 0 ]; then
            log_message "INFO" "Retry ${retry}/${MAX_RETRIES} after 1 second delay"
            sleep 1
        fi
        
        # Check if service is active
        if check_service_active "${SERVICE_NAME}"; then
            # Verify process is actually running
            if check_haproxy_process; then
                log_message "INFO" "Service check passed: ${SERVICE_NAME} is active"
                
                # Perform additional checks
                local checks_passed=7  # Start with 7 points, deduct for failures
                local critical_failure=false
                
                # Check configuration
                if check_haproxy_config; then
                    log_message "DEBUG" "Config check passed"
                else
                    log_message "CRITICAL" "Config check failed"
                    checks_passed=$((checks_passed - 1))
                    critical_failure=true
                fi
                
                # Check listening ports
                local port_result
                if check_listening_ports; then
                    log_message "DEBUG" "Port check passed"
                else
                    local port_issues=$?
                    if [ ${port_issues} -ge 10 ]; then
                        log_message "CRITICAL" "Port check failed - no ports listening"
                        checks_passed=$((checks_passed - 2))
                        critical_failure=true
                    else
                        log_message "WARNING" "Port check failed - some ports not listening"
                        checks_passed=$((checks_passed - 1))
                    fi
                fi
                
                # Check PID file
                if check_pid_file; then
                    log_message "DEBUG" "PID file check passed"
                else
                    log_message "WARNING" "PID file check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check stats socket
                if check_stats_socket; then
                    log_message "DEBUG" "Stats socket check passed"
                else
                    log_message "WARNING" "Stats socket check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check stats HTTP
                if check_stats_http; then
                    log_message "DEBUG" "HTTP stats check passed"
                else
                    log_message "WARNING" "HTTP stats check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check backend health
                if check_backend_health; then
                    log_message "DEBUG" "Backend health check passed"
                else
                    log_message "WARNING" "Backend health check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check HTTP health
                if check_http_health; then
                    log_message "DEBUG" "HTTP health check passed"
                else
                    log_message "WARNING" "HTTP health check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Get detailed service status
                get_service_status "${SERVICE_NAME}"
                
                # Determine final status
                if ${critical_failure}; then
                    log_message "ERROR" "HAProxy has critical issues"
                    return 1  # Failure due to critical issue
                elif [ ${checks_passed} -ge 5 ]; then
                    log_message "INFO" "HAProxy is healthy (score: ${checks_passed}/7)"
                    return 0  # Success
                elif [ ${checks_passed} -ge 3 ]; then
                    log_message "WARNING" "HAProxy has issues but is functional (score: ${checks_passed}/7)"
                    return 1  # Warning
                else
                    log_message "ERROR" "HAProxy has serious issues (score: ${checks_passed}/7)"
                    return 1  # Failure
                fi
            else
                log_message "WARNING" "Service marked active but no HAProxy process found"
                get_service_status "${SERVICE_NAME}"
                return 1  # Warning
            fi
        else
            if [ ${retry} -eq ${MAX_RETRIES} ]; then
                log_message "ERROR" "Service ${SERVICE_NAME} is not active after ${MAX_RETRIES} retries"
                get_service_status "${SERVICE_NAME}"
                return 1  # Failure
            fi
        fi
        
        retry=$((retry + 1))
    done
    
    return 1  # Should not reach here
}

show_usage() {
    cat << EOF
HAProxy Load Balancer Health Check
Usage: $0 [OPTIONS]

Options:
  -h, --help        Show this help message
  -d, --debug       Enable debug output
  -q, --quiet       Quiet mode (errors only)
  --check-config    Only check configuration syntax
  --check-ports     Only check listening ports
  --check-backends  Only check backend health
  --check-http      Only perform HTTP health check
  --stats-socket PATH  Use custom stats socket path
  --stats-port PORT    Use custom stats port

Examples:
  $0                      # Full health check
  $0 --debug             # With debug output
  $0 --check-config      # Only check configuration
  $0 --check-backends    # Only check backend health
  $0 --stats-socket /run/haproxy/admin.sock

Exit Codes:
  0 - OK: HAProxy is healthy
  1 - WARNING/ERROR: HAProxy has issues or is down
  2 - CRITICAL: Service not found or configuration error
EOF
}
# ========== END FUNCTIONS ==========

# ========== MAIN EXECUTION ==========
main() {
    # Parse command line arguments
    local check_mode="full"
    local quiet_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--debug)
                # Already logging everything
                shift
                ;;
            -q|--quiet)
                quiet_mode=true
                exec >/dev/null 2>&1
                shift
                ;;
            --check-config)
                check_mode="config"
                shift
                ;;
            --check-ports)
                check_mode="ports"
                shift
                ;;
            --check-backends)
                check_mode="backends"
                shift
                ;;
            --check-http)
                check_mode="http"
                shift
                ;;
            --stats-socket)
                if [ -n "$2" ]; then
                    STATS_SOCKET="$2"
                    shift 2
                else
                    log_message "ERROR" "Stats socket path not specified"
                    exit 2
                fi
                ;;
            --stats-port)
                if [ -n "$2" ]; then
                    STATS_PORT="$2"
                    shift 2
                else
                    log_message "ERROR" "Stats port not specified"
                    exit 2
                fi
                ;;
            *)
                log_message "WARNING" "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Initialize log file
    if [ ! -f "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}" 2>/dev/null || true
    fi
    
    # Check if service exists
    if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        log_message "CRITICAL" "HAProxy service '${SERVICE_NAME}' not found"
        [ "${quiet_mode}" = false ] && echo "CRITICAL: HAProxy service not found"
        exit 2
    fi
    
    # Perform requested check
    local exit_code=0
    case "${check_mode}" in
        "full")
            if perform_health_check; then
                [ "${quiet_mode}" = false ] && echo "OK: HAProxy is healthy"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "ERROR: HAProxy has issues"
                exit_code=1
            fi
            ;;
        "config")
            if check_haproxy_config; then
                [ "${quiet_mode}" = false ] && echo "OK: HAProxy configuration is valid"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "ERROR: HAProxy configuration has errors"
                exit_code=1
            fi
            ;;
        "ports")
            if check_listening_ports; then
                [ "${quiet_mode}" = false ] && echo "OK: HAProxy ports are listening"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: Some HAProxy ports are not listening"
                exit_code=1
            fi
            ;;
        "backends")
            if check_backend_health; then
                [ "${quiet_mode}" = false ] && echo "OK: HAProxy backends are healthy"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: Some HAProxy backends have issues"
                exit_code=1
            fi
            ;;
        "http")
            if check_http_health; then
                [ "${quiet_mode}" = false ] && echo "OK: HTTP health check passed"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: HTTP health check failed"
                exit_code=1
            fi
            ;;
    esac
    
    exit ${exit_code}
}

# Trap for cleanup
trap 'rm -f /tmp/haproxy_test.log /tmp/haproxy_status.log /tmp/haproxy_stats.csv /tmp/curl_output.log 2>/dev/null || true' EXIT

# Run main function
main "$@"
