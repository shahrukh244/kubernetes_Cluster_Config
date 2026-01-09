#!/bin/bash
# Chrony NTP Service Health Check - Enhanced Version

set -o errexit
set -o nounset

# ========== CONFIGURATION ==========
readonly SERVICE_NAMES=("chrony" "chronyd")  # Different distros use different names
readonly LOG_FILE="/var/log/check_chrony.log"
readonly MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB max log size
readonly MAX_RETRIES=2
readonly CHECK_TIMEOUT=5                  # seconds
readonly NTP_PORT="123"                   # NTP port
readonly MAX_OFFSET_MS=1000               # Max acceptable offset in milliseconds
readonly MAX_DRIFT_PPM=500                # Max acceptable drift in ppm
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

detect_chrony_service() {
    # Try to detect which chrony service is available
    for service in "${SERVICE_NAMES[@]}"; do
        if systemctl list-unit-files | grep -q "^${service}.service"; then
            echo "${service}"
            return 0
        fi
    done
    
    # Check for any chrony-related service
    local possible_service
    possible_service=$(systemctl list-unit-files | grep -E "^(chrony|chronyd)" | head -1 | cut -d. -f1)
    
    if [ -n "${possible_service}" ]; then
        echo "${possible_service}"
        return 0
    else
        log_message "ERROR" "No chrony service found (checked: ${SERVICE_NAMES[*]})"
        return 1
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

check_chrony_process() {
    # Check for chronyd process
    if pgrep -x "chronyd" >/dev/null 2>&1; then
        # Get process details
        local pids
        pids=$(pgrep -x "chronyd" | tr '\n' ' ')
        local process_count
        process_count=$(echo "${pids}" | wc -w)
        
        log_message "INFO" "chronyd process running - PIDs: ${pids} (${process_count} processes)"
        
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
        log_message "WARNING" "No chronyd process found"
        return 1
    fi
}

check_ntp_port() {
    # Check if NTP port (123) is listening
    local port_issues=0
    
    # Check UDP port (NTP typically uses UDP)
    if ss -lun 2>/dev/null | grep -q ":${NTP_PORT} "; then
        log_message "DEBUG" "UDP port ${NTP_PORT} is listening"
    else
        log_message "WARNING" "UDP port ${NTP_PORT} is not listening"
        port_issues=$((port_issues + 1))
    fi
    
    # Check TCP port (some NTP implementations use TCP)
    if ss -ltn 2>/dev/null | grep -q ":${NTP_PORT} "; then
        log_message "DEBUG" "TCP port ${NTP_PORT} is listening"
    fi
    
    return ${port_issues}
}

check_chronyc_tracking() {
    # Check chrony tracking status
    if ! command -v chronyc >/dev/null 2>&1; then
        log_message "WARNING" "chronyc command not found, skipping tracking check"
        return 1
    fi
    
    log_message "DEBUG" "Checking chrony tracking status..."
    
    # Get tracking information
    if chronyc tracking >/dev/null 2>&1; then
        local tracking_output
        tracking_output=$(chronyc tracking 2>/dev/null)
        
        # Extract key metrics
        local system_time_offset
        system_time_offset=$(echo "${tracking_output}" | grep "^System time" | awk '{print $4}' | tr -d '+')
        local last_offset
        last_offset=$(echo "${tracking_output}" | grep "^Last offset" | awk '{print $4}')
        local rms_offset
        rms_offset=$(echo "${tracking_output}" | grep "^RMS offset" | awk '{print $4}')
        local frequency
        frequency=$(echo "${tracking_output}" | grep "^Frequency" | awk '{print $2}' | tr -d '(')
        local residual_freq
        residual_freq=$(echo "${tracking_output}" | grep "^Residual freq" | awk '{print $3}')
        local skew
        skew=$(echo "${tracking_output}" | grep "^Skew" | awk '{print $2}')
        local root_delay
        root_delay=$(echo "${tracking_output}" | grep "^Root delay" | awk '{print $3}')
        local root_dispersion
        root_dispersion=$(echo "${tracking_output}" | grep "^Root dispersion" | awk '{print $3}')
        
        log_message "INFO" "Chrony tracking - Offset: ${last_offset}s, RMS: ${rms_offset}s, Freq: ${frequency}ppm"
        
        # Check if offset is within acceptable range
        if [ -n "${last_offset}" ]; then
            # Convert offset to milliseconds (absolute value)
            local offset_ms
            offset_ms=$(echo "${last_offset} * 1000" | bc 2>/dev/null | awk '{if ($1<0) print -$1; else print $1}')
            
            if [ -n "${offset_ms}" ] && [ "$(echo "${offset_ms} > ${MAX_OFFSET_MS}" | bc 2>/dev/null)" = "1" ]; then
                log_message "WARNING" "Time offset is too large: ${offset_ms}ms (max: ${MAX_OFFSET_MS}ms)"
                return 1
            fi
        fi
        
        # Check frequency drift
        if [ -n "${frequency}" ]; then
            local abs_freq
            abs_freq=$(echo "${frequency}" | awk '{if ($1<0) print -$1; else print $1}')
            
            if [ -n "${abs_freq}" ] && [ "$(echo "${abs_freq} > ${MAX_DRIFT_PPM}" | bc 2>/dev/null)" = "1" ]; then
                log_message "WARNING" "Frequency drift is too high: ${abs_freq}ppm (max: ${MAX_DRIFT_PPM}ppm)"
                return 1
            fi
        fi
        
        # Check if system is synchronized
        local leap_status
        leap_status=$(echo "${tracking_output}" | grep "^Leap status" | awk '{print $3}')
        
        if [ "${leap_status}" = "Normal" ]; then
            log_message "INFO" "Leap status: Normal (synchronized)"
            return 0
        elif [ "${leap_status}" = "Not synchronized" ]; then
            log_message "WARNING" "Leap status: Not synchronized"
            return 1
        else
            log_message "INFO" "Leap status: ${leap_status}"
            return 0
        fi
    else
        log_message "WARNING" "Failed to get chrony tracking information"
        return 1
    fi
}

check_chronyc_sources() {
    # Check NTP sources
    if ! command -v chronyc >/dev/null 2>&1; then
        log_message "WARNING" "chronyc command not found, skipping sources check"
        return 1
    fi
    
    log_message "DEBUG" "Checking chrony sources..."
    
    # Get sources information
    if chronyc sources >/dev/null 2>&1; then
        local sources_output
        sources_output=$(chronyc sources 2>/dev/null)
        local source_count
        source_count=$(echo "${sources_output}" | grep -c "^\^\*\|^\^+\|^\^-" || echo "0")
        local reachable_sources
        reachable_sources=$(echo "${sources_output}" | grep -c "^\^\*\|^\^+" || echo "0")
        
        log_message "INFO" "NTP sources: ${reachable_sources}/${source_count} reachable"
        
        if [ "${reachable_sources}" -eq 0 ]; then
            log_message "WARNING" "No reachable NTP sources"
            return 1
        elif [ "${reachable_sources}" -lt $((source_count / 2 + 1)) ]; then
            log_message "WARNING" "Less than half of NTP sources are reachable"
            return 1
        else
            log_message "INFO" "Sufficient NTP sources are reachable"
            
            # Show top sources
            echo "${sources_output}" | head -10 | while read -r line; do
                log_message "DEBUG" "  ${line}"
            done
            return 0
        fi
    else
        log_message "WARNING" "Failed to get chrony sources information"
        return 1
    fi
}

check_systemd_timesync() {
    # Check if systemd-timesyncd is interfering
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        log_message "WARNING" "systemd-timesyncd is active - may interfere with chrony"
        return 1
    fi
    
    log_message "DEBUG" "systemd-timesyncd is not active"
    return 0
}

get_service_status() {
    local service_name="$1"
    
    log_message "DEBUG" "Getting status for service: ${service_name}"
    
    # Capture service status
    if systemctl status "${service_name}" --no-pager >/tmp/chrony_status.log 2>&1; then
        # Extract relevant status info
        local active_line
        active_line=$(grep -i "active:" /tmp/chrony_status.log | head -1)
        log_message "INFO" "Service status: ${active_line}"
        
        # Check for recent errors
        if grep -i "error\|failed\|failed to\|unable to" /tmp/chrony_status.log | tail -3; then
            log_message "WARNING" "Service logs contain errors"
        fi
    else
        log_message "WARNING" "Failed to get service status"
    fi
}

perform_health_check() {
    local retry=0
    local service_name
    
    log_message "INFO" "Starting chrony NTP service health check"
    
    # Detect service name
    if ! service_name=$(detect_chrony_service); then
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
            if check_chrony_process; then
                log_message "INFO" "Service check passed: ${service_name} is active"
                
                # Perform additional checks
                local checks_passed=4  # Start with 4 points, deduct for failures
                local critical_failure=false
                
                # Check NTP port
                if check_ntp_port; then
                    log_message "INFO" "Port check passed"
                else
                    log_message "WARNING" "Port check failed - NTP port not listening"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check chrony tracking
                if check_chronyc_tracking; then
                    log_message "INFO" "Tracking check passed"
                else
                    log_message "WARNING" "Tracking check failed - time may not be synchronized"
                    checks_passed=$((checks_passed - 1))
                    critical_failure=true
                fi
                
                # Check NTP sources
                if check_chronyc_sources; then
                    log_message "INFO" "Sources check passed"
                else
                    log_message "WARNING" "Sources check failed - insufficient NTP sources"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Check for interfering services
                if check_systemd_timesync; then
                    log_message "DEBUG" "No interfering services detected"
                else
                    log_message "WARNING" "Potential service conflict detected"
                    checks_passed=$((checks_passed - 1))
                fi
                
                # Get detailed service status
                get_service_status "${service_name}"
                
                # Determine final status
                if ${critical_failure}; then
                    log_message "ERROR" "Chrony service has critical synchronization issues"
                    return 1  # Failure due to critical issue
                elif [ ${checks_passed} -ge 3 ]; then
                    log_message "INFO" "Chrony NTP service is healthy (score: ${checks_passed}/4)"
                    return 0  # Success
                else
                    log_message "WARNING" "Chrony NTP service has issues but is running (score: ${checks_passed}/4)"
                    return 1  # Warning
                fi
            else
                log_message "WARNING" "Service marked active but no chronyd process found"
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
Chrony NTP Service Health Check
Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message
  -d, --debug     Enable debug output
  -q, --quiet     Quiet mode (errors only)
  --check-tracking  Only check time tracking/synchronization
  --check-sources   Only check NTP sources
  --check-ports     Only check listening ports

Examples:
  $0                   # Full health check
  $0 --debug          # With debug output
  $0 --check-tracking # Only check time synchronization
  $0 --check-sources  # Only check NTP sources

Exit Codes:
  0 - OK: Service is healthy and synchronized
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
            --check-tracking)
                check_mode="tracking"
                shift
                ;;
            --check-sources)
                check_mode="sources"
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
                [ "${quiet_mode}" = false ] && echo "OK: Chrony NTP service is healthy and synchronized"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "ERROR: Chrony NTP service has issues"
                exit_code=1
            fi
            ;;
        "tracking")
            if check_chronyc_tracking; then
                [ "${quiet_mode}" = false ] && echo "OK: Time is properly synchronized"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: Time synchronization issues detected"
                exit_code=1
            fi
            ;;
        "sources")
            if check_chronyc_sources; then
                [ "${quiet_mode}" = false ] && echo "OK: Sufficient NTP sources available"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: Insufficient NTP sources"
                exit_code=1
            fi
            ;;
        "ports")
            if check_ntp_port; then
                [ "${quiet_mode}" = false ] && echo "OK: NTP ports are listening"
                exit_code=0
            else
                [ "${quiet_mode}" = false ] && echo "WARNING: NTP ports are not listening"
                exit_code=1
            fi
            ;;
    esac
    
    exit ${exit_code}
}

# Trap for cleanup
trap 'rm -f /tmp/chrony_status.log 2>/dev/null || true' EXIT

# Run main function
main "$@"
