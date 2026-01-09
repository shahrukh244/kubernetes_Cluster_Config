#!/bin/bash
# DHCP Service Health Check - Minimal Enhanced Version

set -o errexit
set -o nounset

readonly SERVICE_NAME="isc-dhcp-server"
readonly LOG_FILE="/var/log/check_dhcp.log"
readonly MAX_RETRIES=2

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Main check with retries
check_dhcp_service() {
    local retry=0
    
    while [ ${retry} -le ${MAX_RETRIES} ]; do
        # Check if service exists
        if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
            log "ERROR: Service ${SERVICE_NAME} not found"
            return 2  # Service not found
        fi
        
        # Check if service is active
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            # Verify process is actually running
            if pgrep -x "dhcpd" >/dev/null 2>&1; then
                log "INFO: Service ${SERVICE_NAME} is active and running"
                return 0  # Success
            else
                log "WARNING: Service marked active but no dhcpd process found"
                return 1  # Warning
            fi
        fi
        
        # If not active and we have retries left, wait and retry
        if [ ${retry} -lt ${MAX_RETRIES} ]; then
            log "WARNING: Service ${SERVICE_NAME} not active, retry $((retry + 1))/${MAX_RETRIES}"
            sleep 1
        fi
        
        retry=$((retry + 1))
    done
    
    # All retries failed
    log "ERROR: Service ${SERVICE_NAME} is not active after ${MAX_RETRIES} retries"
    
    # Optional: Try to get service status for debugging
    systemctl status "${SERVICE_NAME}" --no-pager | tail -20 >> "${LOG_FILE}" 2>&1 || true
    
    return 1  # Failure
}

# Run check
if check_dhcp_service; then
    exit 0
else
    exit 1
fi
