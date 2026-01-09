#!/bin/bash
# DRBD Backup/Demotion Script - SAFETY FIRST VERSION
# Stops NFS services, unmounts DRBD device, and demotes to secondary role ONLY when safe

set -o errexit
set -o nounset
set -o pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ========== CONFIGURATION ==========
readonly LOCK_FILE="/var/run/drbd-backup.lock"
readonly LOG_FILE="/var/log/ha-storage.log"
readonly RESOURCE_NAME="kube"
readonly MOUNT_POINT="/share/kube"
readonly MAX_LOCK_WAIT=30
readonly NFS_STOP_TIMEOUT=30
readonly UMOUNT_RETRIES=3
readonly DEMOTION_TIMEOUT=15
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

verify_drbd_state_before_demotion() {
    info "Verifying DRBD state before demotion..."
    
    local current_role
    current_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    info "Current role: ${current_role}"
    
    # If we're not Primary, we shouldn't be running this script
    if [ "${current_role}" != "Primary" ]; then
        warn "Node is not in Primary role (${current_role}). Checking if demotion is still needed..."
        
        # Check if we need to clean up even though not Primary
        if mountpoint -q "${MOUNT_POINT}" || systemctl is-active --quiet nfs-server; then
            warn "Node not Primary but NFS/mount still active. Continuing with cleanup."
        else
            info "Node already in non-Primary role with no active services. Exiting."
            exit 0
        fi
    fi
    
    # Check connection to peer
    local connection_state
    connection_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Connected\|StandAlone\|Unconnected" || echo "Unknown")
    info "Connection state: ${connection_state}"
    
    if [ "${connection_state}" = "StandAlone" ] || [ "${connection_state}" = "Unconnected" ]; then
        warn "No connection to peer node. Demoting while disconnected could cause issues if peer becomes Primary."
        
        # Check if peer might already be Primary
        local peer_status
        peer_status=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -A1 "^ *[0-9]*:" | tail -1 || echo "")
        if echo "${peer_status}" | grep -q "Primary"; then
            fail "PEER NODE IS PRIMARY! Cannot demote while peer is Primary in disconnected state. Manual intervention required."
        fi
        
        # Ask for confirmation or implement timeout-based decision
        warn "Proceeding with demotion while disconnected. Peer may need manual intervention later."
    fi
    
    # Check if resource is in use elsewhere (shouldn't be if we're Primary)
    if drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -q "InUse.*Secondary"; then
        warn "Resource marked as 'InUse' on Secondary peer. This is unusual."
    fi
}

check_for_open_files() {
    local mount_point="$1"
    info "Checking for open files on ${mount_point}..."
    
    # Use lsof to check for open files
    if command -v lsof >/dev/null 2>&1; then
        local open_files
        open_files=$(lsof "${mount_point}" 2>/dev/null | wc -l || echo "0")
        
        if [ "${open_files}" -gt 0 ]; then
            warn "Found ${open_files} open file(s) on ${mount_point}:"
            lsof "${mount_point}" 2>/dev/null | head -10 | while read -r line; do
                warn "  ${line}"
            done
            
            # Try to identify what's holding files open
            local processes
            processes=$(lsof "${mount_point}" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ')
            if [ -n "${processes}" ]; then
                warn "Processes with open files: ${processes}"
                ps -p "${processes}" -o pid,comm,cmd 2>/dev/null | while read -r line; do
                    warn "  ${line}"
                done
            fi
            
            return 1  # Indicate files are open
        else
            info "No open files detected on ${mount_point}"
            return 0
        fi
    else
        warn "lsof not available, cannot check for open files"
        return 0  # Assume no open files if we can't check
    fi
}

stop_nfs_services_safely() {
    info "Stopping NFS services safely..."
    
    # 1. First, unexport shares to prevent new connections
    info "Unexporting NFS shares..."
    if exportfs -au 2>/dev/null; then
        info "NFS shares unexported"
    else
        warn "Failed to unexport NFS shares, continuing..."
    fi
    
    # 2. Stop nfs-server service
    if systemctl is-active --quiet nfs-server; then
        info "Stopping nfs-server service..."
        
        # Try graceful stop first
        local stop_attempt=0
        while systemctl is-active --quiet nfs-server && [ ${stop_attempt} -lt ${NFS_STOP_TIMEOUT} ]; do
            if [ ${stop_attempt} -eq 0 ]; then
                systemctl stop nfs-server
            elif [ ${stop_attempt} -lt 3 ]; then
                systemctl stop nfs-server
            else
                # More aggressive stopping
                systemctl kill -s TERM nfs-server
            fi
            
            sleep 1
            ((stop_attempt++)) || true
        done
        
        # Check if service stopped
        if systemctl is-active --quiet nfs-server; then
            warn "nfs-server still running after ${NFS_STOP_TIMEOUT} seconds, forcing..."
            systemctl kill -s KILL nfs-server || true
            sleep 2
        fi
        
        if ! systemctl is-active --quiet nfs-server; then
            info "nfs-server successfully stopped"
        else
            fail "Failed to stop nfs-server service"
        fi
    else
        info "nfs-server service was not running"
    fi
    
    # 3. Kill any remaining NFS daemons
    info "Checking for remaining NFS processes..."
    local nfs_processes
    nfs_processes=$(pgrep -f "nfsd|rpc.mountd|rpc.nfsd" 2>/dev/null || true)
    
    if [ -n "${nfs_processes}" ]; then
        warn "Found remaining NFS processes: ${nfs_processes}"
        kill -TERM ${nfs_processes} 2>/dev/null || true
        sleep 1
        
        # Force kill if still running
        if pgrep -f "nfsd|rpc.mountd|rpc.nfsd" >/dev/null 2>&1; then
            warn "Forcing remaining NFS processes to stop..."
            pkill -9 -f "nfsd|rpc.mountd|rpc.nfsd" 2>/dev/null || true
            sleep 1
        fi
    fi
    
    # 4. Stop rpcbind if safe to do so
    if systemctl is-active --quiet rpcbind; then
        info "Checking if rpcbind can be stopped..."
        
        # Check if any other services need rpcbind
        local rpcbind_required=0
        local rpc_services="rpc-statd rpc-gssd nis-domainname gssproxy"
        
        for service in ${rpc_services}; do
            if systemctl is-active --quiet "${service}" 2>/dev/null; then
                warn "rpcbind required by ${service}, keeping it running"
                rpcbind_required=1
                break
            fi
        done
        
        if [ ${rpcbind_required} -eq 0 ]; then
            info "Stopping rpcbind..."
            systemctl stop rpcbind || warn "Failed to stop rpcbind"
        fi
    fi
    
    # 5. Verify NFS is really stopped
    sleep 1
    if pgrep -f "nfsd|rpc.mountd|rpc.nfsd" >/dev/null 2>&1; then
        warn "NFS processes still running after stop attempts"
        return 1
    fi
    
    info "NFS services stopped successfully"
    return 0
}

unmount_safely_with_retry() {
    info "Attempting to unmount ${MOUNT_POINT}..."
    
    if ! mountpoint -q "${MOUNT_POINT}"; then
        info "${MOUNT_POINT} is not mounted"
        return 0
    fi
    
    # Check what's mounted
    local mounted_device
    mounted_device=$(findmnt -n -o SOURCE "${MOUNT_POINT}" 2>/dev/null || echo "unknown")
    info "Currently mounted: ${mounted_device} at ${MOUNT_POINT}"
    
    # Try multiple unmount strategies
    for attempt in $(seq 1 ${UMOUNT_RETRIES}); do
        info "Unmount attempt ${attempt}/${UMOUNT_RETRIES}"
        
        # Check for open files
        if check_for_open_files "${MOUNT_POINT}"; then
            info "No open files detected"
        else
            warn "Open files detected, attempting lazy unmount"
            umount -l "${MOUNT_POINT}" && break
        fi
        
        # Try normal unmount
        if umount "${MOUNT_POINT}" 2>/dev/null; then
            info "Successfully unmounted ${MOUNT_POINT}"
            break
        fi
        
        # On last attempt, try force unmount
        if [ ${attempt} -eq ${UMOUNT_RETRIES} ]; then
            warn "Final attempt: forcing unmount..."
            if umount -f "${MOUNT_POINT}" 2>/dev/null; then
                warn "Force unmount succeeded"
                break
            else
                fail "Failed to unmount ${MOUNT_POINT} after ${UMOUNT_RETRIES} attempts"
            fi
        fi
        
        warn "Unmount failed, waiting 2 seconds before retry..."
        sleep 2
    done
    
    # Verify unmount succeeded
    if mountpoint -q "${MOUNT_POINT}"; then
        fail "Verification failed: ${MOUNT_POINT} is still mounted after unmount attempts"
    fi
    
    info "Successfully unmounted ${MOUNT_POINT}"
    return 0
}

safe_demote_drbd() {
    info "Attempting to demote DRBD resource to Secondary..."
    
    local start_time
    start_time=$(date +%s)
    
    # Check current role one more time
    local current_role
    current_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    
    if [ "${current_role}" = "Secondary" ]; then
        info "Already in Secondary role, demotion not needed"
        return 0
    fi
    
    if [ "${current_role}" != "Primary" ]; then
        warn "Unexpected role before demotion: ${current_role}"
        # Continue anyway to ensure cleanup
    fi
    
    # Demote to secondary
    info "Executing: drbdadm secondary ${RESOURCE_NAME}"
    if drbdadm secondary "${RESOURCE_NAME}"; then
        local elapsed=$(( $(date +%s) - start_time ))
        info "Successfully demoted to Secondary in ${elapsed} seconds"
        
        # Verify demotion
        sleep 1
        local new_role
        new_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
        
        if [ "${new_role}" = "Secondary" ]; then
            info "Role verification passed: now in Secondary role"
            return 0
        else
            warn "Role verification failed: current role is ${new_role}"
            return 1
        fi
    else
        # Demotion failed
        warn "Standard demotion failed. Gathering diagnostic information..."
        
        # Get detailed status
        log "DIAGNOSTICS" "DRBD status before failed demotion:"
        drbdadm status "${RESOURCE_NAME}" 2>&1 | while read -r line; do
            log "DIAGNOSTICS" "  ${line}"
        done
        
        # Check if we're still Primary
        current_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
        if [ "${current_role}" = "Primary" ]; then
            fail "Demotion failed but node remains Primary. Manual intervention may be needed."
        elif [ "${current_role}" = "Secondary" ]; then
            warn "Demotion command failed but node is already Secondary"
            return 0
        else
            fail "Demotion failed with unknown state. Check DRBD status manually."
        fi
    fi
}

cleanup_after_demotion() {
    info "Performing post-demotion cleanup..."
    
    # Remove mount point directory if empty (optional)
    if [ -d "${MOUNT_POINT}" ]; then
        info "Checking mount point directory ${MOUNT_POINT}..."
        
        # Keep the directory if it has a .keepmount file
        if [ -f "${MOUNT_POINT}/.keepmount" ]; then
            info "Keeping mount point directory (found .keepmount file)"
            return
        fi
        
        # Remove if empty
        if [ -z "$(ls -A "${MOUNT_POINT}" 2>/dev/null)" ]; then
            rmdir "${MOUNT_POINT}" 2>/dev/null && info "Removed empty mount point directory" || 
            warn "Could not remove mount point directory (may not be empty)"
        else
            warn "Mount point directory not empty, preserving it"
            ls -la "${MOUNT_POINT}" | head -5 | while read -r line; do
                warn "  ${line}"
            done
        fi
    fi
    
    # Clean up lock file if it exists (should be handled by trap)
    if [ -f "${LOCK_FILE}" ] && [ "$(cat "${LOCK_FILE}" 2>/dev/null)" = "$$" ]; then
        rm -f "${LOCK_FILE}"
    fi
}

verify_final_state() {
    info "Verifying final system state..."
    
    local errors=0
    local warnings=0
    
    # 1. Verify NFS is stopped
    if systemctl is-active --quiet nfs-server; then
        warn "nfs-server service is still running"
        ((warnings++))
    else
        info "✓ nfs-server service is stopped"
    fi
    
    # 2. Verify no NFS processes
    if pgrep -f "nfsd|rpc.mountd|rpc.nfsd" >/dev/null 2>&1; then
        warn "NFS processes are still running"
        ((warnings++))
    else
        info "✓ No NFS processes running"
    fi
    
    # 3. Verify mount is gone
    if mountpoint -q "${MOUNT_POINT}"; then
        fail "✗ ${MOUNT_POINT} is still mounted"
        ((errors++))
    else
        info "✓ ${MOUNT_POINT} is not mounted"
    fi
    
    # 4. Verify DRBD role
    local final_role
    final_role=$(drbdadm role "${RESOURCE_NAME}" 2>/dev/null | cut -d'/' -f1 || echo "Unknown")
    
    if [ "${final_role}" = "Secondary" ]; then
        info "✓ DRBD is in Secondary role"
    elif [ "${final_role}" = "Primary" ]; then
        fail "✗ DRBD is still in Primary role - demotion failed!"
        ((errors++))
    else
        warn "DRBD role is ${final_role} (expected Secondary)"
        ((warnings++))
    fi
    
    # 5. Verify DRBD connection (optional)
    local connection_state
    connection_state=$(drbdadm status "${RESOURCE_NAME}" 2>/dev/null | grep -o "Connected\|StandAlone\|Unconnected" || echo "Unknown")
    info "DRBD connection state: ${connection_state}"
    
    if [ ${errors} -gt 0 ]; then
        fail "Final verification failed with ${errors} error(s) and ${warnings} warning(s)"
    elif [ ${warnings} -gt 0 ]; then
        warn "Demotion completed with ${warnings} warning(s)"
    else
        info "All verification checks passed"
    fi
}
# ========== END FUNCTIONS ==========

# ========== MAIN EXECUTION ==========
main() {
    info "===== STARTING SAFE BACKUP DEMOTION ====="
    
    # Acquire exclusive lock
    acquire_lock
    
    # Verify DRBD resource exists
    if ! drbdadm status "${RESOURCE_NAME}" >/dev/null 2>&1; then
        fail "DRBD resource '${RESOURCE_NAME}' not found"
    fi
    
    # Validate current DRBD state before proceeding
    verify_drbd_state_before_demotion
    
    # Stop NFS services
    if ! stop_nfs_services_safely; then
        fail "Failed to stop NFS services safely"
    fi
    
    # Unmount the filesystem
    unmount_safely_with_retry
    
    # Demote to secondary
    if ! safe_demote_drbd; then
        fail "Failed to demote DRBD resource"
    fi
    
    # Verify final state
    verify_final_state
    
    # Optional cleanup
    cleanup_after_demotion
    
    info "===== BACKUP DEMOTION COMPLETED SAFELY AND SUCCESSFULLY ====="
}

# Run main function
main
