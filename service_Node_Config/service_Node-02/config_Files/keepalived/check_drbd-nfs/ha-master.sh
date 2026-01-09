#!/bin/bash
# DRBD Master Promotion Script - SAFETY FIRST VERSION
# Promotes node to primary role ONLY when safe, mounts DRBD device, and starts NFS services

set -o errexit          # Exit on any error
set -o nounset          # Exit on undefined variables
set -o pipefail         # Catch pipe failures

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ========== CONFIGURATION ==========
readonly LOCK_FILE="/var/run/drbd-master.lock"
readonly LOG_FILE="/var/log/ha-storage.log"
readonly RESOURCE_NAME="kube"
readonly MOUNT_POINT="/share/kube"
readonly MAX_LOCK_WAIT=30  # seconds
readonly SYNC_TIMEOUT=300   # seconds for sync wait
readonly PROMOTION_TIMEOUT=10  # seconds for promotion attempt
# ===================================

# ========== FUNCTIONS ==========
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

fail() {
    log "ERROR" "$1"
    exit 1
}

warn() {
    log "WARN" "$1"
}

info() {
    log "INFO" "$1"
}

acquire_lock() {
    local lock_attempt=0
    while [ -f "${LOCK_FILE}" ]; do
        if [ ${lock_attempt} -ge ${MAX_LOCK_WAIT} ]; then
            fail "Could not acquire lock after ${MAX_LOCK_WAIT} seconds"
        fi
        warn "Lock file exists, waiting... (attempt $((lock_attempt + 1)))"
        sleep 1
        ((lock_attempt++)) || true
    done
    echo "$$" > "${LOCK_FILE}" || fail "Failed to create lock file"
    trap 'release_lock' EXIT TERM INT
    info "Lock acquired"
}

release_lock() {
    if [ -f "${LOCK_FILE}" ] && [ "$(cat "${LOCK_FILE}")" = "$$" ]; then
        rm -f "${LOCK_FILE}"
        info "Lock released"
    fi
}

check_drbd_connection() {
    info "Checking DRBD connection state..."
    local connection_state
    connection_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Connected" || echo "")
    
    if [ -z "${connection_state}" ]; then
        local disk_state
        disk_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Diskless\|Failed\|Inconsistent" || echo "")
        if [ -n "${disk_state}" ]; then
            fail "DRBD resource is in '${disk_state}' state"
        else
            warn "DRBD connection state unknown, proceeding with caution"
        fi
    else
        info "DRBD is connected"
    fi
}

check_drbd_sync() {
    info "Checking DRBD synchronization..."
    local sync_info
    sync_info=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "sync'ed:[0-9.]*%" || echo "")
    
    if [ -n "${sync_info}" ]; then
        local percent
        percent=$(echo "${sync_info}" | cut -d: -f2 | cut -d% -f1)
        info "Synchronization: ${percent}% complete"
        
        if [ "$(echo "${percent} < 100.0" | bc 2>/dev/null)" = "1" ]; then
            warn "DRBD not fully synchronized. Waiting up to ${SYNC_TIMEOUT} seconds..."
            
            local wait_time=0
            while [ "$(echo "${percent} < 100.0" | bc 2>/dev/null)" = "1" ] && [ ${wait_time} -lt ${SYNC_TIMEOUT} ]; do
                sleep 5
                sync_info=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "sync'ed:[0-9.]*%" || echo "")
                percent=$(echo "${sync_info}" | cut -d: -f2 | cut -d% -f1)
                info "Synchronization progress: ${percent}%"
                ((wait_time+=5)) || true
            done
            
            if [ "$(echo "${percent} < 100.0" | bc 2>/dev/null)" = "1" ]; then
                warn "Timeout waiting for full synchronization"
            fi
        fi
    fi
}

check_peer_role() {
    info "Checking peer node role..."
    local peer_role
    peer_role=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | 
                grep -A1 "^ *[0-9]*:" | 
                grep -v "^ *[0-9]*:" | 
                grep -o "Primary\|Secondary" || echo "Unknown")
    
    if [ "${peer_role}" = "Primary" ]; then
        fail "Peer node is already Primary! Cannot promote this node. Check peer node status."
    elif [ "${peer_role}" = "Secondary" ]; then
        info "Peer node is in Secondary role - safe to promote"
    elif [ "${peer_role}" = "Unknown" ]; then
        warn "Could not determine peer role (connection may be down)"
        # Check if connection is actually down
        if drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -q "StandAlone\|Unconnected\|Connecting"; then
            info "Connection to peer is down. Promoting without peer is acceptable."
        else
            warn "Connection exists but peer role unknown. Proceeding with caution."
        fi
    fi
}

get_drbd_device() {
    local device
    device=$(drbdadm sh-dev "${RESOURCE_NAME}" 2>/dev/null || drbdadm show-gi "${RESOURCE_NAME}" 2>/dev/null | awk '/device:/ {print $2}')
    
    if [ -z "${device}" ]; then
        # Try common DRBD device paths
        if [ -e "/dev/drbd0" ]; then
            echo "/dev/drbd0"
        elif [ -e "/dev/drbd/by-res/${RESOURCE_NAME}/0" ]; then
            echo "/dev/drbd/by-res/${RESOURCE_NAME}/0"
        else
            fail "Could not determine DRBD device for resource '${RESOURCE_NAME}'"
        fi
    else
        echo "${device}"
    fi
}

check_filesystem() {
    local device="$1"
    info "Checking filesystem on ${device}..."
    
    # Check if filesystem is already mounted
    if mountpoint -q "${MOUNT_POINT}"; then
        local mounted_device
        mounted_device=$(findmnt -n -o SOURCE "${MOUNT_POINT}" 2>/dev/null || echo "")
        if [ "${mounted_device}" = "${device}" ]; then
            info "Device ${device} is already mounted at ${MOUNT_POINT}"
            return 0
        else
            fail "${MOUNT_POINT} is mounted with different device: ${mounted_device}"
        fi
    fi
    
    # Check filesystem type and integrity
    if ! blkid "${device}" >/dev/null 2>&1; then
        fail "Device ${device} does not appear to have a valid filesystem"
    fi
}

safe_promote_drbd() {
    info "Attempting to promote DRBD resource to Primary (NO FORCE FLAG)..."
    
    local start_time
    start_time=$(date +%s)
    
    # Try promotion without --force
    if drbdadm primary "${RESOURCE_NAME}"; then
        local elapsed=$(( $(date +%s) - start_time ))
        info "Successfully promoted to Primary in ${elapsed} seconds"
        return 0
    fi
    
    # If promotion failed, provide detailed diagnostics
    warn "Standard promotion failed. Gathering diagnostic information..."
    
    local current_role
    current_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    local connection_state
    connection_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Connected\|StandAlone\|Unconnected\|Connecting\|Disconnecting" || echo "Unknown")
    local peer_role
    peer_role=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | 
                grep -A1 "^ *[0-9]*:" | 
                grep -v "^ *[0-9]*:" | 
                grep -o "Primary\|Secondary" || echo "Unknown")
    
    log "DIAGNOSTICS" "Current role: ${current_role}"
    log "DIAGNOSTICS" "Connection state: ${connection_state}"
    log "DIAGNOSTICS" "Peer role: ${peer_role}"
    log "DIAGNOSTICS" "Full status:"
    drbdadm status "${RESOURCE_NAME}" 2>&1 | while read -r line; do
        log "DIAGNOSTICS" "  ${line}"
    done
    
    if [ "${peer_role}" = "Primary" ]; then
        fail "Cannot promote: Peer node is already Primary! This would cause split-brain. Manual intervention required."
    elif [ "${current_role}" = "Primary" ]; then
        warn "Already in Primary role despite promotion failure"
        return 0
    else
        fail "DRBD promotion failed. Check diagnostics above. DO NOT use --force unless you have verified fencing is in place."
    fi
}

start_nfs_services() {
    info "Starting NFS services..."
    
    # Start rpcbind if not running
    if ! systemctl is-active --quiet rpcbind; then
        info "Starting rpcbind..."
        systemctl start rpcbind || warn "Failed to start rpcbind"
    fi
    
    # Start nfs-server
    if ! systemctl is-active --quiet nfs-server; then
        info "Starting nfs-server..."
        systemctl start nfs-server || fail "Failed to start nfs-server"
    fi
    
    # Export filesystems
    info "Exporting NFS shares..."
    if ! exportfs -rav; then
        fail "Failed to export filesystems"
    fi
    
    # Verify NFS is working
    sleep 2
    if ! showmount -e localhost >/dev/null 2>&1; then
        warn "NFS exports not showing on localhost, but continuing"
    fi
}

emergency_procedure() {
    local reason="$1"
    warn "EMERGENCY PROCEDURE INITIATED: ${reason}"
    warn "If you are CERTAIN the other node is dead and won't come back:"
    warn "1. Manually verify the other node is powered off or disconnected"
    warn "2. On this node, run: drbdadm primary --force ${RESOURCE_NAME}"
    warn "3. Only then run this script again"
    warn "Using --force without proper fencing can cause DATA CORRUPTION!"
    fail "Emergency stop to prevent data corruption"
}
# ========== END FUNCTIONS ==========

# ========== MAIN EXECUTION ==========
main() {
    info "===== STARTING SAFE MASTER PROMOTION (NO --force) ====="
    
    # Acquire exclusive lock
    acquire_lock
    
    # Verify DRBD resource exists
    if ! drbdadm status "${RESOURCE_NAME}" >/dev/null 2>&1; then
        fail "DRBD resource '${RESOURCE_NAME}' not found"
    fi
    
    # Check current role
    local current_role
    current_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    info "Current DRBD role: ${current_role}"
    
    if [ "${current_role}" = "Primary" ]; then
        info "Already in Primary role"
    else
        # Check connection state
        check_drbd_connection
        
        # Check peer role to prevent split-brain
        check_peer_role
        
        # Check synchronization
        check_drbd_sync
        
        # SAFELY promote to primary (NO --force flag)
        safe_promote_drbd
        
        # Wait for udev to settle
        udevadm settle --timeout=10 || warn "udev settle timed out"
    fi
    
    # Get DRBD device
    local drbd_device
    drbd_device=$(get_drbd_device)
    info "Using DRBD device: ${drbd_device}"
    
    # Verify device exists
    if [ ! -e "${drbd_device}" ]; then
        fail "DRBD device ${drbd_device} does not exist"
    fi
    
    # Check filesystem
    check_filesystem "${drbd_device}"
    
    # Mount if not already mounted
    if ! mountpoint -q "${MOUNT_POINT}"; then
        info "Mounting ${drbd_device} to ${MOUNT_POINT}..."
        
        # Create mount point if it doesn't exist
        mkdir -p "${MOUNT_POINT}" || fail "Failed to create mount point directory"
        
        # Mount the device
        if ! mount "${drbd_device}" "${MOUNT_POINT}"; then
            fail "Failed to mount ${drbd_device} to ${MOUNT_POINT}"
        fi
        info "Successfully mounted ${drbd_device}"
    fi
    
    # Start NFS services
    start_nfs_services
    
    # Verify everything is working
    info "Verifying setup..."
    if ! mountpoint -q "${MOUNT_POINT}"; then
        fail "Mount verification failed"
    fi
    
    if ! drbdadm role "${RESOURCE_NAME}" | grep -q "Primary"; then
        fail "Role verification failed"
    fi
    
    info "===== MASTER PROMOTION COMPLETED SAFELY AND SUCCESSFULLY ====="
}

# Run main function
main
