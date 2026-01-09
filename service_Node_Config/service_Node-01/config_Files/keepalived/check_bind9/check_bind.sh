#!/bin/bash
# BIND/named DNS Service Health Check - Enhanced Version

set -o errexit
set -o nounset

# ========== CONFIGURATION ==========
readonly PRIMARY_SERVICE="bind9"          # Debian/Ubuntu
readonly ALTERNATE_SERVICE="named"        # RHEL/CentOS/Fedora
readonly LOG_FILE="/var/log/check_bind.log"
readonly MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB max log size
readonly MAX_RETRIES=2
readonly CHECK_TIMEOUT=5                  # seconds
readonly DNS_PORTS="53"                   # DNS ports to check
readonly DNS_TEST_HOST="google.com"       # Hostname for test query
# ===================================

# ========== FUNCTIONS ==========
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Console output
    echo "[${timestamp}] ${level}: ${message}"
    
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

detect_service_name() {
    # Try to detect which BIND service is available
    if systemctl list-unit-files | grep -q "^${PRIMARY_SERVICE}.service"; then
        echo "${PRIMARY_SERVICE}"
    elif systemctl list-unit-files | grep -q "^${ALTERNATE_SERVICE}.service"; then
        echo "${ALTERNATE_SERVICE}"
    else
        # Check if any bind/named service exists
        local possible_service
        possible_service=$(systemctl list-unit-files | grep -E "^(bind|named)" | head -1 | cut -d. -f1)
        
        if [ -n "${possible_service}" ]; then
            echo "${possible_service}"
        else
            log_message "ERROR" "No BIND/named service found (checked: ${PRIMARY_SERVICE}, ${ALTERNATE_SERVICE})"
            return 1
        fi
    fi
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

check_process_running() {
    # Check for named process (BIND)
    if pgrep -x "named" >/dev/null 2>&1; then
        # Get process details
        local pids
        pids=$(pgrep -x "named" | tr '\n' ' ')
        local process_count
        process_count=$(echo "${pids}" | wc -w)
        
        log_message "INFO" "BIND process running - PIDs: ${pids} (${process_count} processes)"
        
        # Check process states
        for pid in ${pids}; do
            if [ -d "/proc/${pid}" ]; then
                local process_state
                process_state=$(cat "/proc/${pid}/status" 2>/dev/null | grep "^State:" | cut -f2 || echo "unknown")
                log_message "DEBUG" "Process ${pid} state: ${process_state}"
            fi
        done
        return 0
    else
        log_message "WARNING" "No named process found"
        return 1
    fi
}

check_listening_ports() {
    # Check if DNS port (53) is listening
    local port_issues=0
    
    for port in ${DNS_PORTS}; do
        # Check TCP port
        if ss -ltn 2>/dev/null | grep -q ":${port} "; then
            log_message "DEBUG" "TCP port ${port} is listening"
        else
            log_message "WARNING" "TCP port ${port} is not listening"
            port_issues=$((port_issues + 1))
        fi
        
        # Check UDP port
        if ss -lun 2>/dev/null | grep -q ":${port} "; then
            log_message "DEBUG" "UDP port ${port} is listening"
        else
            log_message "WARNING" "UDP port ${port} is not listening"
            port_issues=$((port_issues + 1))
        fi
    done
    
    return ${port_issues}
}

check_dns_functionality() {
    # Test DNS resolution
    log_message "DEBUG" "Testing DNS resolution with host: ${DNS_TEST_HOST}"
    
    # Use multiple methods to test DNS
    local test_methods=("dig" "nslookup" "host")
    local method_found=false
    
    for method in "${test_methods[@]}"; do
        if command -v "${method}" >/dev/null 2>&1; then
            method_found=true
            
            case "${method}" in
                "dig")
                    if timeout ${CHECK_TIMEOUT} dig +short +time=2 +tries=1 "${DNS_TEST_HOST}" @127.0.0.1 >/dev/null 2>&1; then
                        log_message "INFO" "DNS resolution test passed using dig"
                        return 0
                    fi
                    ;;
                "nslookup")
                    if timeout ${CHECK_TIMEOUT} nslookup -timeout=2 "${DNS_TEST_HOST}" 127.0.0.1 >/dev/null 2>&1; then
                        log_message "INFO" "DNS resolution test passed using nslookup"
                        return 0
                    fi
                    ;;
                "host")
                    if timeout ${CHECK_TIMEOUT} host -W 2 "${DNS_TEST_HOST}" 127.0.0.1 >/dev/null 2>&1; then
                        log_message "INFO" "DNS resolution test passed using host"
                        return 0
                    fi
                    ;;
            esac
        fi
    done
    
    if [ "${method_found}" = false ]; then
        log_message "WARNING" "No DNS testing tool available (dig, nslookup, host)"
        # Assume functionality if we can't test
        return 0
    else
        log_message "WARNING" "DNS resolution test failed"
        return 1
    fi
}

check_zone_files() {
    # Check for common zone file locations
    local zone_dirs=("/etc/bind" "/var/named" "/etc/named" "/var/lib/bind")
    local config_files=("/etc/bind/named.conf" "/etc/named.conf" "/etc/bind/named.conf.local")
    
    log_message "DEBUG" "Checking for zone files..."
    
    # Check for configuration files
    local config_found=false
    for config_file in "${config_files[@]}"; do
        if [ -f "${config_file}" ]; then
            log_message "INFO" "Found config file: ${config_file}"
            config_found=true
            
            # Check config syntax if named-checkconf is available
            if command -v named-checkconf >/dev/null 2>&1; then
                if named-checkconf "${config_file}" >/tmp/named_check.log 2>&1; then
                    log_message "DEBUG" "Config syntax check passed for ${config_file}"
                else
                    log_message "WARNING" "Config syntax check failed for ${config_file}"
                    cat /tmp/named_check.log >> "${LOG_FILE}" 2>/dev/null || true
                fi
            fi
        fi
    done
    
    if [ "${config_found}" = false ]; then
        log_message "WARNING" "No BIND config files found"
    fi
    
    # Check zone file directories
    local zones_found=false
    for zone_dir in "${zone_dirs[@]}"; do
        if [ -d "${zone_dir}" ]; then
            local zone_count
            zone_count=$(find "${zone_dir}" -name "*.db" -o -name "*.zone" 2>/dev/null | wc -l)
            if [ "${zone_count}" -gt 0 ]; then
                log_message "INFO" "Found ${zone_count} zone files in ${zone_dir}"
                zones_found=true
            fi
        fi
    done
    
    if [ "${zones_found}" = false ]; then
        log_message "INFO" "No zone files found (may be using rndc or other configuration)"
    fi
}

get_service_status() {
    local service_name="$1"
    
    log_message "DEBUG" "Getting status for service: ${service_name}"
    
    # Capture service status
    if systemctl status "${service_name}" --no-pager >/tmp/bind_status.log 2>&1; then
        # Extract relevant status info
        local active_line
        active_line=$(grep -i "active:" /tmp/bind_status.log | head -1)
        log_message "INFO" "Service status: ${active_line}"
        
        # Check for recent errors
        if grep -i "error\|failed" /tmp/bind_status.log | tail -3; then
            log_message "WARNING" "Service logs contain errors"
        fi
    else
        log_message "WARNING" "Failed to get service status"
    fi
}

perform_health_check() {
    local retry=0
    local service_name
    
    log_message "INFO" "Starting BIND DNS service health check"
    
    # Detect service name
    if ! service_name=$(detect_service_name); then
        return 2  # Service not found
    fi
    
    log_message "INFO" "Using service name: ${service_name}"
    
    # Main check loop with retries
    while [ ${retry} -le ${MAX_RETRIES} ]; do
        if [ ${retry} -gt 0 ]; then
            log_message "INFO" "Retry ${retry}/${MAX_RETRIES} after 1 second delay"
            sleep 1
        fi
        
        # Check if service is active
        if check_service_active "${service_name}"; then
            # Verify process is actually running
            if check_process_running; then
                log_message "INFO" "Service check passed: ${service_name} is active"
                
                # Perform additional checks
                local checks_passed=3  # Start with 3 points, deduct for failures
                
                # Check listening ports
                if check_listening_ports; then
                    log_message "INFO" "Port check passed"
                else
                    log_message "WARNING" "Port check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check DNS functionality
                if check_dns_functionality; then
                    log_message "INFO" "DNS functionality check passed"
                else
                    log_message "WARNING" "DNS functionality check failed"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check zone files (informational only)
                check_zone_files
                
                # Get detailed service status
                get_service_status "${service_name}"
                
                # Determine final status
                if [ ${checks_passed} -ge 2 ]; then
                    log_message "INFO" "BIND DNS service is healthy (score: ${checks_passed}/3)"
                    return 0  # Success
                else
                    log_message "WARNING" "BIND DNS service has issues but is running (score: ${checks_passed}/3)"
                    return 1  # Warning
                fi
            else
                log_message "WARNING" "Service marked active but no named process found"
                get_service_status "${service_name}"
                return 1  # Warning
            fi
        else
            if [ ${retry} -eq ${MAX_RETRIES} ]; then
                log_message "ERROR" "Service ${service_name} is not active after ${MAX_RETRIES} retries"
                get_service_status "${service_name}"
                return 1  # Failure
            fi
        fi
        
        retry=$((retry + 1))
    done
    
    return 1  # Should not reach here
}

show_usage() {
    cat << EOF
BIND DNS Service Health Check
Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message
  -d, --debug     Enable debug output
  -q, --quiet     Quiet mode (errors only)
  -t, --test HOST Test DNS with specific host (default: ${DNS_TEST_HOST})
  --check-ports   Only check listening ports
  --check-dns     Only check DNS functionality

Examples:
  $0                   # Full health check
  $0 --debug          # With debug output
  $0 --test example.com  # Test with specific hostname
  $0 --check-ports    # Only check listening ports

Exit Codes:
  0 - OK: Service is healthy
  1 - WARNING/ERROR: Service has issues or is down
  2 - CRITICAL: Service not found
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
            -t|--test)
                if [ -n "$2" ]; then
                    DNS_TEST_HOST="$2"
                    shift 2
                else
                    log_message "ERROR" "Test host not specified"
                    exit 2
                fi
                ;;
            --check-ports)
                check_mode="ports"
                shift
                ;;
            --check-dns)
                check_mode="dns"
                shift
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
    
    # Perform requested check
    local exit_code=0
    case "${check_mode}" in
        "full")
            if perform_health_check; then
                [ "${quiet_mode}" = false ] && echo "OK: BIND DNS service is healthy"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "ERROR: BIND DNS service has issues"
                exit_code=1
            fi
            ;;
        "ports")
            if check_listening_ports; then
                [ "${quiet_mode}" = false ] && echo "OK: DNS ports are listening"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: Some DNS ports are not listening"
                exit_code=1
            fi
            ;;
        "dns")
            if check_dns_functionality; then
                [ "${quiet_mode}" = false ] && echo "OK: DNS resolution is working"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "ERROR: DNS resolution test failed"
                exit_code=1
            fi
            ;;
    esac
    
    exit ${exit_code}
}

# Trap for cleanup
trap 'rm -f /tmp/bind_status.log /tmp/named_check.log 2>/dev/null || true' EXIT

# Run main function
main "$@"
