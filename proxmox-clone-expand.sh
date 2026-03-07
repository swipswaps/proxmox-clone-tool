#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/proxmox-clone-expand.log"
SOURCE_VMID=""
NEW_VMID=""
NEW_NAME=""
EXPAND_SIZE=""
DRY_RUN=false
MAX_RETRIES=20
RETRY_INTERVAL=2

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run() { 
    if [ "$DRY_RUN" = true ]; then 
        log "[DRY-RUN] $*"; 
    else 
        log "[RUN] $*"; 
        eval "$@" 2>&1 | tee -a "$LOG_FILE"; 
        return "${PIPESTATUS[0]}"; 
    fi
}

parse_args() {
    log "Parsing arguments..."
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) SOURCE_VMID="$2"; shift 2 ;;
            --target) NEW_VMID="$2"; shift 2 ;;
            --name)   NEW_NAME="$2"; shift 2 ;;
            --expand) EXPAND_SIZE="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) log "ERROR: Unknown argument $1"; exit 1 ;;
        esac
    done
    [[ -z "$SOURCE_VMID" || -z "$NEW_VMID" || -z "$NEW_NAME" || -z "$EXPAND_SIZE" ]] && { log "ERROR: Missing required arguments"; exit 1; }
    log "Arguments OK: source=$SOURCE_VMID, target=$NEW_VMID, name=$NEW_NAME, expand=$EXPAND_SIZE, dry-run=$DRY_RUN"
}

preflight_checks() {
    log "Running pre-flight checks..."
    command -v qm >/dev/null || { log "ERROR: qm CLI not found"; exit 1; }
    command -v pvesm >/dev/null || { log "ERROR: pvesm CLI not found"; exit 1; }
    if [ "$DRY_RUN" = false ]; then
        qm status "$SOURCE_VMID" >/dev/null || { log "ERROR: Source VM $SOURCE_VMID not found"; exit 1; }
        if qm status "$NEW_VMID" >/dev/null 2>&1; then log "ERROR: Target VMID $NEW_VMID exists"; exit 1; fi
    fi
    log "Pre-flight checks passed."
}

detect_storage() {
    log "Detecting storage for VM $SOURCE_VMID..."
    STORAGE=$( [ "$DRY_RUN" = true ] && echo "local-lvm" || qm config "$SOURCE_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f2 | cut -d',' -f1 | xargs )
    [[ -z "$STORAGE" ]] && { log "ERROR: could not detect storage"; exit 1; }

    # Determine storage type robustly
    if vgs "$STORAGE" >/dev/null 2>&1; then
        STORAGE_TYPE="lvm"
    elif zfs list "$STORAGE" >/dev/null 2>&1; then
        STORAGE_TYPE="zfs"
    elif [ -d "/mnt/$STORAGE" ]; then
        STORAGE_TYPE="dir"
    elif rbd showmapped | grep -q "$STORAGE"; then
        STORAGE_TYPE="ceph"
    else
        log "ERROR: Unknown or inaccessible storage type: $STORAGE"; exit 1
    fi

    log "Storage verified: $STORAGE (type=$STORAGE_TYPE)"
}

check_existing_snapshots() {
    log "Checking for snapshots..."
    if [ "$DRY_RUN" = false ]; then
        SNAP_WARN=$(qm listsnapshot "$SOURCE_VMID" 2>/dev/null || true)
        [[ -n "$SNAP_WARN" ]] && log "Existing snapshots:\n$SNAP_WARN"
    fi
    log "Snapshot check complete."
}

check_storage() {
    log "Checking available storage..."
    local req=$(echo "$EXPAND_SIZE" | sed 's/G//')
    local free
    free=$( [ "$DRY_RUN" = true ] && echo "500" || pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//' )
    if ! [[ "$free" =~ ^[0-9]+$ ]]; then log "ERROR: Storage check failed ($free)"; exit 1; fi
    (( free < req )) && { log "ERROR: insufficient storage ($free G < $req G)"; exit 1; }
    log "Sufficient storage: $free G"
}

prepare_snapshot() {
    local ts=$(date '+%Y%m%d-%H%M%S')
    SNAP_NAME="pre-clone-$ts"
    log "Creating snapshot: $SNAP_NAME"
    [ "$DRY_RUN" = false ] && run qm snapshot "$SOURCE_VMID" "$SNAP_NAME" || log "[DRY-RUN] Snapshot $SNAP_NAME simulated"
}

wait_vm_config() {
    log "Waiting for VM $NEW_VMID config..."
    local tries=0
    while [ "$tries" -lt $MAX_RETRIES ]; do
        [ "$DRY_RUN" = true ] && break
        [[ -f "/etc/pve/qemu-server/${NEW_VMID}.conf" ]] && { log "VM config detected"; return; }
        log "Config not ready, retrying..."; sleep $RETRY_INTERVAL; ((tries++))
    done
    log "ERROR: VM config not found after retries"; exit 1
}

detect_disk() {
    log "Detecting primary disk..."
    local tries=0
    while [ "$tries" -lt $MAX_RETRIES ]; do
        DISK=$( [ "$DRY_RUN" = true ] && echo "scsi0" || qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f1 )
        [[ -n "$DISK" ]] && { log "Disk detected: $DISK"; return; }
        log "Disk not ready, retrying..."; sleep $RETRY_INTERVAL; ((tries++))
    done
    log "ERROR: Cannot detect disk"; exit 1
}

detect_root_partition() {
    log "Detecting root partition via guest agent..."
    local tries=0
    while [ "$tries" -lt $MAX_RETRIES ]; do
        ROOT_PART=$( [ "$DRY_RUN" = true ] && echo "sda1" || qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT | awk '$2=="/"{print $1}' )
        [[ -n "$ROOT_PART" ]] && break
        log "Root partition not detected, retrying..."; sleep $RETRY_INTERVAL; ((tries++))
    done
    [[ -z "$ROOT_PART" ]] && { log "ERROR: root partition not found"; exit 1; }
    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
    log "Root partition: $ROOT_PART, Disk=$DISK_NAME, Part#=$PART_NUM"
}

expand_filesystem() {
    local FS_TYPE=$( [ "$DRY_RUN" = true ] && echo "ext4" || qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART" )
    log "Filesystem type: $FS_TYPE"
    case "$FS_TYPE" in
        xfs) run qm guest exec "$NEW_VMID" -- bash -c "command -v xfs_growfs >/dev/null || exit 1; xfs_growfs /" ;;
        ext2|ext3|ext4) run qm guest exec "$NEW_VMID" -- bash -c "command -v resize2fs >/dev/null || exit 1; resize2fs /dev/$ROOT_PART" ;;
        btrfs) run qm guest exec "$NEW_VMID" -- bash -c "command -v btrfs >/dev/null || exit 1; btrfs filesystem resize max /" ;;
        *) log "WARNING: Unknown filesystem $FS_TYPE; skipping resize" ;;
    esac
}

verify_post_clone() {
    log "Verifying post-clone VM state..."
    run qm guest exec "$NEW_VMID" -- df -h
    run qm guest exec "$NEW_VMID" -- lsblk
    run qm guest exec "$NEW_VMID" -- hostnamectl
}

# ------------------------- MAIN ------------------------------
parse_args "$@"
log "==== START Proxmox Clone + Expand ===="
preflight_checks
detect_storage
check_existing_snapshots
check_storage
prepare_snapshot
run qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true
wait_vm_config
run qm start "$NEW_VMID"
detect_disk
detect_root_partition
run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"
expand_filesystem
run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A
verify_post_clone
log "==== COMPLETE ===="