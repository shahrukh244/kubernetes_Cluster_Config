#!/bin/bash
# DHCP Service Health Check Script
# Enhanced version with monitoring, logging, and diagnostics

set -o errexit          # Exit on error
set -o nounset          # Exit on undefined variables
set -o pipefail         # Catch pipe failures

# ========== CONFIGURATION ==========
readonly SERVICE_NAME="isc-dhcp-server"
readonly ALTERNATE_SERVICE_NAME="dhcpd"  # For different distros
readonly LOG_FILE="/var/log/check_dhcp.log"
readonly MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB max log size
readonly CHECK_TIMEOUT=5  # seconds for service checks
readonly PORT_CHECK_TIMEOUT=3  # seconds for port checks
readonly DHCP_PORTS="67 68"    # DHCP ports to check

# Nagios/Icinga compatible exit codes
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3
# ===================================

# ========== FUNCTIONS ==========
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Console output for monitoring systems
    case "$level" in
        "CRITICAL")
            echo "[${timestamp}] [CRITICAL] ${message}" >&2
            ;;
        "WARNING")
            echo "[${timestamp}] [WARNING] ${message}" >&1
            ;;
        "INFO")
            echo "[${timestamp}] [INFO] ${message}" >&1
            ;;
        "DEBUG")
            # Only output if DEBUG flag is set
            [ "${DEBUG:-false}" = "true" ] && echo "[${timestamp}] [DEBUG] ${message}" >&1
            ;;
    esac
    
    # Log to file with rotation check
    log_to_file "${timestamp}" "${level}" "${message}"
}

log_to_file() {
    local timestamp="$1"
    local level="$2"
    local message="$3"
    
    # Check if log file exists and its size
    if [ -f "${LOG_FILE}" ] && [ "$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)" -gt ${MAX_LOG_SIZE} ]; then
        # Rotate log file
        mv "${LOG_FILE}" "${LOG_FILE}.old" 2>/dev/null || true
    fi
    
    # Write to log file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

check_service_active() {
    local service_name="$1"
    log_message "DEBUG" "Checking if service '${service_name}' is active..."
    
    # Use timeout to prevent hanging
    if timeout ${CHECK_TIMEOUT} systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        log_message "DEBUG" "Service '${service_name}' is active"
        return 0
    else
        log_message "DEBUG" "Service '${service_name}' is not active"
        return 1
    fi
}

check_service_enabled() {
    local service_name="$1"
    log_message "DEBUG" "Checking if service '${service_name}' is enabled..."
    
    if systemctl is-enabled "${service_name}" 2>/dev/null | grep -q "enabled"; then
        log_message "DEBUG" "Service '${service_name}' is enabled"
        return 0
    else
        log_message "DEBUG" "Service '${service_name}' is not enabled"
        return 1
    fi
}

check_service_exists() {
    local service_name="$1"
    log_message "DEBUG" "Checking if service '${service_name}' exists..."
    
    if systemctl list-unit-files | grep -q "^${service_name}.service"; then
        log_message "DEBUG" "Service '${service_name}' exists"
        return 0
    else
        log_message "DEBUG" "Service '${service_name}' does not exist"
        return 1
    fi
}

check_dhcp_ports() {
    log_message "DEBUG" "Checking DHCP ports (${DHCP_PORTS})..."
    
    local port_issues=0
    for port in ${DHCP_PORTS}; do
        # Check if port is listening
        if timeout ${PORT_CHECK_TIMEOUT} bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
            log_message "DEBUG" "Port ${port} is listening"
        else
            log_message "WARNING" "Port ${port} is not listening"
            port_issues=$((port_issues + 1))
        fi
    done
    
    return ${port_issues}
}

check_dhcp_process() {
    log_message "DEBUG" "Checking for DHCP processes..."
    
    # Look for dhcpd process
    if pgrep -x "dhcpd" >/dev/null 2>&1; then
        log_message "DEBUG" "dhcpd process is running"
        
        # Get process details
        local pids
        pids=$(pgrep -x "dhcpd" | tr '\n' ' ')
        log_message "INFO" "DHCP process PIDs: ${pids}"
        
        # Check process health
        for pid in ${pids}; do
            if [ -d "/proc/${pid}" ]; then
                local process_state
                process_state=$(cat "/proc/${pid}/status" 2>/dev/null | grep "^State:" | cut -f2 || echo "unknown")
                log_message "DEBUG" "Process ${pid} state: ${process_state}"
            fi
        done
        return 0
    else
        log_message "WARNING" "No dhcpd process found"
        return 1
    fi
}

check_dhcp_leases() {
    local leases_file="/var/lib/dhcp/dhcpd.leases"
    local alt_leases_file="/var/lib/dhcpd/dhcpd.leases"
    
    log_message "DEBUG" "Checking DHCP leases file..."
    
    # Find leases file
    if [ -f "${leases_file}" ]; then
        LEASES_FILE="${leases_file}"
    elif [ -f "${alt_leases_file}" ]; then
        LEASES_FILE="${alt_leases_file}"
    else
        log_message "WARNING" "Could not find DHCP leases file"
        return 1
    fi
    
    log_message "INFO" "Using leases file: ${LEASES_FILE}"
    
    # Check if leases file is readable and has entries
    if [ -r "${LEASES_FILE}" ]; then
        local lease_count
        lease_count=$(grep -c "^lease " "${LEASES_FILE}" 2>/dev/null || echo "0")
        local active_leases
        active_leases=$(grep -c "binding state active" "${LEASES_FILE}" 2>/dev/null || echo "0")
        
        log_message "INFO" "Total leases: ${lease_count}, Active leases: ${active_leases}"
        
        if [ "${lease_count}" -gt 0 ]; then
            # Check when leases file was last modified
            local last_modified
            last_modified=$(stat -c "%y" "${LEASES_FILE}" 2>/dev/null || echo "unknown")
            log_message "DEBUG" "Leases file last modified: ${last_modified}"
            return 0
        else
            log_message "WARNING" "Leases file exists but contains no leases"
            return 1
        fi
    else
        log_message "WARNING" "Cannot read leases file: ${LEASES_FILE}"
        return 1
    fi
}

check_dhcp_config() {
    local config_file="/etc/dhcp/dhcpd.conf"
    local alt_config_file="/etc/dhcpd.conf"
    
    log_message "DEBUG" "Checking DHCP configuration..."
    
    # Find config file
    if [ -f "${config_file}" ]; then
        CONFIG_FILE="${config_file}"
    elif [ -f "${alt_config_file}" ]; then
        CONFIG_FILE="${alt_config_file}"
    else
        log_message "CRITICAL" "Could not find DHCP configuration file"
        return 1
    fi
    
    log_message "INFO" "Using config file: ${CONFIG_FILE}"
    
    # Check config syntax if dhcpd is available
    if command -v dhcpd >/dev/null 2>&1; then
        log_message "DEBUG" "Testing DHCP configuration syntax..."
        
        # Test configuration (dry run)
        if dhcpd -t -cf "${CONFIG_FILE}" >/tmp/dhcpd_test.log 2>&1; then
            log_message "INFO" "DHCP configuration syntax is valid"
            return 0
        else
            log_message "CRITICAL" "DHCP configuration syntax error"
            cat /tmp/dhcpd_test.log >> "${LOG_FILE}" 2>/dev/null || true
            return 1
        fi
    else
        log_message "WARNING" "dhcpd command not found, skipping config test"
        return 0
    fi
}

get_service_status() {
    local service_name="$1"
    log_message "DEBUG" "Getting detailed status for service '${service_name}'..."
    
    # Get full service status
    if systemctl status "${service_name}" --no-pager >/tmp/service_status.log 2>&1; then
        log_message "DEBUG" "Service status command succeeded"
        return 0
    else
        local exit_code=$?
        log_message "DEBUG" "Service status command exited with code ${exit_code}"
        
        # Capture error output
        if [ -s /tmp/service_status.log ]; then
            log_message "INFO" "Service status output:"
            while read -r line; do
                log_message "INFO" "  ${line}"
            done < /tmp/service_status.log
        fi
        return ${exit_code}
    fi
}

attempt_service_restart() {
    local service_name="$1"
    
    # Only attempt restart if AUTO_RESTART is enabled
    if [ "${AUTO_RESTART:-false}" = "true" ]; then
        log_message "WARNING" "Attempting to restart service '${service_name}'..."
        
        if systemctl restart "${service_name}" 2>/dev/null; then
            log_message "INFO" "Service restart initiated"
            
            # Wait a moment and check if it's now active
            sleep 2
            if check_service_active "${service_name}"; then
                log_message "INFO" "Service restart successful"
                return 0
            else
                log_message "CRITICAL" "Service restart failed - still inactive"
                return 1
            fi
        else
            log_message "CRITICAL" "Failed to restart service"
            return 1
        fi
    else
        log_message "DEBUG" "Auto-restart disabled (set AUTO_RESTART=true to enable)"
        return 1
    fi
}

perform_health_check() {
    local service_found=false
    local service_active=false
    local overall_health=0
    
    log_message "INFO" "Starting DHCP service health check..."
    
    # Try primary service name first
    if check_service_exists "${SERVICE_NAME}"; then
        service_found=true
        ACTIVE_SERVICE="${SERVICE_NAME}"
        
        # Check if service is enabled
        if check_service_enabled "${ACTIVE_SERVICE}"; then
            log_message "INFO" "Service '${ACTIVE_SERVICE}' is enabled"
        else
            log_message "WARNING" "Service '${ACTIVE_SERVICE}' is not enabled"
            overall_health=$((overall_health + 1))
        fi
        
        # Check if service is active
        if check_service_active "${ACTIVE_SERVICE}"; then
            service_active=true
            log_message "INFO" "Service '${ACTIVE_SERVICE}' is active"
        else
            log_message "CRITICAL" "Service '${ACTIVE_SERVICE}' is not active"
            overall_health=$((overall_health + 2))
            
            # Get detailed status
            get_service_status "${ACTIVE_SERVICE}"
            
            # Optionally attempt restart
            if [ "${overall_health}" -ge 2 ]; then
                attempt_service_restart "${ACTIVE_SERVICE}"
            fi
        fi
    # Try alternate service name
    elif check_service_exists "${ALTERNATE_SERVICE_NAME}"; then
        service_found=true
        ACTIVE_SERVICE="${ALTERNATE_SERVICE_NAME}"
        
        if check_service_enabled "${ACTIVE_SERVICE}"; then
            log_message "INFO" "Service '${ACTIVE_SERVICE}' is enabled"
        else
            log_message "WARNING" "Service '${ACTIVE_SERVICE}' is not enabled"
            overall_health=$((overall_health + 1))
        fi
        
        if check_service_active "${ACTIVE_SERVICE}"; then
            service_active=true
            log_message "INFO" "Service '${ACTIVE_SERVICE}' is active"
        else
            log_message "CRITICAL" "Service '${ACTIVE_SERVICE}' is not active"
            overall_health=$((overall_health + 2))
            get_service_status "${ACTIVE_SERVICE}"
            
            if [ "${overall_health}" -ge 2 ]; then
                attempt_service_restart "${ACTIVE_SERVICE}"
            fi
        fi
    else
        log_message "CRITICAL" "No DHCP service found (checked: ${SERVICE_NAME}, ${ALTERNATE_SERVICE_NAME})"
        return ${EXIT_CRITICAL}
    fi
    
    # If service is active, perform additional checks
    if [ "${service_active}" = true ]; then
        # Check DHCP process
        if check_dhcp_process; then
            log_message "INFO" "DHCP process check: OK"
        else
            log_message "WARNING" "DHCP process check: FAILED"
            overall_health=$((overall_health + 1))
        fi
        
        # Check DHCP ports
        if check_dhcp_ports; then
            log_message "INFO" "DHCP port check: OK"
        else
            log_message "WARNING" "DHCP port check: FAILED - some ports not listening"
            overall_health=$((overall_health + 1))
        fi
        
        # Check DHCP configuration
        if check_dhcp_config; then
            log_message "INFO" "DHCP config check: OK"
        else
            log_message "CRITICAL" "DHCP config check: FAILED"
            overall_health=$((overall_health + 2))
        fi
        
        # Check DHCP leases (warning only)
        if check_dhcp_leases; then
            log_message "INFO" "DHCP leases check: OK"
        else
            log_message "WARNING" "DHCP leases check: FAILED"
            overall_health=$((overall_health + 1))
        fi
    fi
    
    # Determine final exit code based on overall health
    if [ "${service_active}" = false ]; then
        log_message "CRITICAL" "DHCP service is not running"
        return ${EXIT_CRITICAL}
    elif [ ${overall_health} -ge 2 ]; then
        log_message "CRITICAL" "DHCP service has critical issues (score: ${overall_health})"
        return ${EXIT_CRITICAL}
    elif [ ${overall_health} -eq 1 ]; then
        log_message "WARNING" "DHCP service has minor issues (score: ${overall_health})"
        return ${EXIT_WARNING}
    else
        log_message "INFO" "DHCP service is healthy"
        return ${EXIT_OK}
    fi
}

show_usage() {
    cat << EOF
DHCP Service Health Check Script
Usage: $0 [OPTIONS]

Options:
  -h, --help          Show this help message
  -d, --debug         Enable debug output
  -r, --restart       Attempt to restart service if down (use with caution)
  -q, --quiet         Quiet mode (minimal output)
  -n, --nagios        Nagios/Icinga compatible output
  -s, --service NAME  Use alternative service name
  --check-config      Only check configuration syntax
  --check-leases      Only check leases file
  --check-ports       Only check listening ports

Examples:
  $0                   # Standard health check
  $0 --debug           # With debug output
  $0 --nagios          # For monitoring systems
  $0 --check-config    # Only validate configuration
  $0 --service dhcpd   # Check alternative service name

Exit Codes:
  0 - OK: Service is healthy
  1 - WARNING: Service has minor issues
  2 - CRITICAL: Service is down or has critical issues
  3 - UNKNOWN: Script error or unable to determine status
EOF
}
# ========== END FUNCTIONS ==========

# ========== MAIN EXECUTION ==========
main() {
    # Parse command line arguments
    local check_mode="full"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--debug)
                export DEBUG="true"
                shift
                ;;
            -r|--restart)
                export AUTO_RESTART="true"
                shift
                ;;
            -q|--quiet)
                # Redirect all output to log file only
                exec >/dev/null 2>&1
                shift
                ;;
            -n|--nagios)
                export NAGIOS_MODE="true"
                shift
                ;;
            -s|--service)
                if [ -n "$2" ]; then
                    export SERVICE_NAME="$2"
                    shift 2
                else
                    log_message "CRITICAL" "Service name not specified"
                    exit ${EXIT_UNKNOWN}
                fi
                ;;
            --check-config)
                check_mode="config"
                shift
                ;;
            --check-leases)
                check_mode="leases"
                shift
                ;;
            --check-ports)
                check_mode="ports"
                shift
                ;;
            *)
                log_message "WARNING" "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Perform requested check
    case "${check_mode}" in
        "full")
            perform_health_check
            exit_code=$?
            ;;
        "config")
            if check_dhcp_config; then
                log_message "INFO" "Configuration check: OK"
                exit_code=${EXIT_OK}
            else
                log_message "CRITICAL" "Configuration check: FAILED"
                exit_code=${EXIT_CRITICAL}
            fi
            ;;
        "leases")
            if check_dhcp_leases; then
                log_message "INFO" "Leases check: OK"
                exit_code=${EXIT_OK}
            else
                log_message "WARNING" "Leases check: FAILED"
                exit_code=${EXIT_WARNING}
            fi
            ;;
        "ports")
            if check_dhcp_ports; then
                log_message "INFO" "Ports check: OK"
                exit_code=${EXIT_OK}
            else
                log_message "WARNING" "Ports check: FAILED"
                exit_code=${EXIT_WARNING}
            fi
            ;;
    esac
    
    # Nagios/Icinga compatible output
    if [ "${NAGIOS_MODE:-false}" = "true" ]; then
        case ${exit_code} in
            ${EXIT_OK})
                echo "OK: DHCP service is healthy"
                ;;
            ${EXIT_WARNING})
                echo "WARNING: DHCP service has minor issues"
                ;;
            ${EXIT_CRITICAL})
                echo "CRITICAL: DHCP service is down or has critical issues"
                ;;
            *)
                echo "UNKNOWN: Unable to determine DHCP service status"
                ;;
        esac
    fi
    
    exit ${exit_code}
}

# Trap for cleanup
trap 'rm -f /tmp/service_status.log /tmp/dhcpd_test.log 2>/dev/null || true' EXIT

# Run main function
main "$@"
