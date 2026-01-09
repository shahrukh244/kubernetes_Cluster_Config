#!/bin/bash
# DRBD Resource Health Check - Enhanced Version for Keepalived

set -o errexit
set -o nounset

# ========== CONFIGURATION ==========
readonly RESOURCE_NAME="kube"              # DRBD resource name (from your config)
readonly LOG_FILE="/var/log/check_drbd.log"
readonly MAX_LOG_SIZE=$((5 * 1024 * 1024))  # 5MB max log size
readonly MAX_RETRIES=1                     # Keepalived will retry, so keep this low
readonly CHECK_TIMEOUT=3                   # seconds (must be less than Keepalived interval)
readonly MIN_SYNC_PERCENT=95.0             # Minimum sync percentage to consider healthy
# ===================================

# ========== FUNCTIONS ==========
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Console output (for Keepalived logging)
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

check_drbd_resource_exists() {
    log_message "DEBUG" "Checking if DRBD resource '${RESOURCE_NAME}' exists..."
    
    if ! drbdadm status "${RESOURCE_NAME}" >/dev/null 2>&1; then
        log_message "ERROR" "DRBD resource '${RESOURCE_NAME}' not found"
        return 1
    fi
    
    log_message "DEBUG" "DRBD resource exists"
    return 0
}

check_drbd_role() {
    log_message "DEBUG" "Checking DRBD role..."
    
    local role
    role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    
    log_message "INFO" "DRBD role: ${role}"
    
    if [ "${role}" = "Primary" ]; then
        log_message "DEBUG" "Resource is in Primary role"
        return 0
    elif [ "${role}" = "Secondary" ]; then
        log_message "WARNING" "Resource is in Secondary role (not suitable for master node)"
        return 1
    else
        log_message "ERROR" "Unexpected DRBD role: ${role}"
        return 1
    fi
}

check_drbd_connection() {
    log_message "DEBUG" "Checking DRBD connection state..."
    
    local connection_state
    connection_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Connected" || echo "")
    
    if [ -n "${connection_state}" ]; then
        log_message "INFO" "DRBD is connected to peer"
        return 0
    else
        # Check specific connection states
        local problem_state
        problem_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | 
                        grep -o "StandAlone\|Unconnected\|Connecting\|Disconnecting\|NetworkFailure\|ProtocolError" || echo "")
        
        if [ -n "${problem_state}" ]; then
            log_message "ERROR" "DRBD connection problem: ${problem_state}"
            return 1
        else
            log_message "WARNING" "DRBD connection state unknown or disconnected"
            return 1
        fi
    fi
}

check_drbd_sync() {
    log_message "DEBUG" "Checking DRBD synchronization..."
    
    local sync_info
    sync_info=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "sync'ed:[0-9.]*%" || echo "")
    
    if [ -n "${sync_info}" ]; then
        local percent
        percent=$(echo "${sync_info}" | cut -d: -f2 | cut -d% -f1)
        log_message "INFO" "DRBD synchronization: ${percent}%"
        
        if [ "$(echo "${percent} < ${MIN_SYNC_PERCENT}" | bc 2>/dev/null)" = "1" ]; then
            log_message "WARNING" "DRBD synchronization below threshold: ${percent}% < ${MIN_SYNC_PERCENT}%"
            return 1
        fi
        return 0
    else
        # Check if resource is fully synchronized or doesn't need sync
        local disk_state
        disk_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "UpToDate" || echo "")
        
        if [ -n "${disk_state}" ]; then
            log_message "INFO" "DRBD disks are UpToDate"
            return 0
        else
            log_message "WARNING" "DRBD synchronization status unknown"
            return 0  # Not a critical failure
        fi
    fi
}

check_drbd_disk_state() {
    log_message "DEBUG" "Checking DRBD disk state..."
    
    local disk_state
    disk_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | 
                 grep -A1 "^\s*[0-9]*:" | 
                 grep -o "UpToDate\|Inconsistent\|Diskless\|Failed" || echo "Unknown")
    
    log_message "INFO" "DRBD disk state: ${disk_state}"
    
    if [ "${disk_state}" = "UpToDate" ] || [ "${disk_state}" = "Consistent" ]; then
        return 0
    elif [ "${disk_state}" = "Inconsistent" ]; then
        log_message "WARNING" "DRBD disk is Inconsistent"
        return 1
    elif [ "${disk_state}" = "Diskless" ] || [ "${disk_state}" = "Failed" ]; then
        log_message "ERROR" "DRBD disk problem: ${disk_state}"
        return 1
    else
        log_message "WARNING" "DRBD disk state unknown: ${disk_state}"
        return 0  # Not a critical failure
    fi
}

check_no_split_brain() {
    log_message "DEBUG" "Checking for split-brain..."
    
    local split_brain_info
    split_brain_info=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -i "split-brain" || echo "")
    
    if [ -n "${split_brain_info}" ]; then
        log_message "ERROR" "SPLIT-BRAIN DETECTED: ${split_brain_info}"
        return 1
    fi
    
    log_message "DEBUG" "No split-brain detected"
    return 0
}

perform_health_check() {
    local retry=0
    
    log_message "INFO" "Starting DRBD health check for resource: ${RESOURCE_NAME}"
    
    while [ ${retry} -le ${MAX_RETRIES} ]; do
        if [ ${retry} -gt 0 ]; then
            log_message "INFO" "Retry ${retry}/${MAX_RETRIES}"
            sleep 0.5  # Short sleep between retries
        fi
        
        # Check if resource exists
        if ! check_drbd_resource_exists; then
            return 1
        fi
        
        # Check role (must be Primary for master node)
        if ! check_drbd_role; then
            return 1
        fi
        
        # Check connection state
        if ! check_drbd_connection; then
            return 1
        fi
        
        # Check for split-brain (critical)
        if ! check_no_split_brain; then
            return 1
        fi
        
        # Check disk state
        if ! check_drbd_disk_state; then
            return 1
        fi
        
        # Check synchronization
        if ! check_drbd_sync; then
            return 1
        fi
        
        log_message "INFO" "DRBD health check passed"
        return 0
        
        retry=$((retry + 1))
    done
    
    return 1
}

show_usage() {
    cat << EOF
DRBD Resource Health Check for Keepalived
Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message
  -d, --debug     Enable debug output
  -q, --quiet     Quiet mode (for Keepalived)
  -r, --resource NAME  Use alternative DRBD resource name

Examples:
  $0                     # Standard check
  $0 --debug            # With debug output
  $0 --quiet            # Quiet mode (minimal output)
  $0 --resource myres   # Check different resource

Exit Codes:
  0 - OK: DRBD is healthy and in Primary role
  1 - ERROR: DRBD has issues or is not Primary
EOF
}
# ========== END FUNCTIONS ==========

# ========== MAIN EXECUTION ==========
main() {
    # Parse command line arguments
    local quiet_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--debug)
                # Debug is default in logging
                shift
                ;;
            -q|--quiet)
                quiet_mode=true
                exec >/dev/null 2>&1
                shift
                ;;
            -r|--resource)
                if [ -n "$2" ]; then
                    RESOURCE_NAME="$2"
                    shift 2
                else
                    echo "ERROR: Resource name not specified" >&2
                    exit 1
                fi
                ;;
            *)
                echo "WARNING: Unknown option: $1" >&2
                shift
                ;;
        esac
    done
    
    # Initialize log file
    if [ ! -f "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}" 2>/dev/null || true
    fi
    
    # Perform health check
    if perform_health_check; then
        [ "${quiet_mode}" = false ] && echo "OK: DRBD resource '${RESOURCE_NAME}' is healthy and Primary"
        exit 0
    else
        [ "${quiet_mode}" = false ] && echo "ERROR: DRBD resource '${RESOURCE_NAME}' check failed"
        exit 1
    fi
}

# Run main function
main "$@"
