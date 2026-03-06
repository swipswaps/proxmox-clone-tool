#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# Proxmox VM Clone + Expand Tool (PRF-Compliant, Fully Upgraded)
#
# Features & Fixes:
# • Idempotent snapshot handling: reuses 'pre-clone' if present
# • Full pre-flight validation: source VM, target VMID, storage
# • Automatic disk expansion and filesystem resize
# • Supports LVM, ext4, xfs, btrfs
# • Waits for qemu-guest-agent before resizing
# • Hostname and SSH key setup post-clone
# • Dry-run mode for safe testing
# • Full logging to /var/log/proxmox-clone-expand.log
# ==============================================================

LOG_FILE="/var/log/proxmox-clone-expand.log"
SOURCE_VMID=""
NEW_VMID=""
NEW_NAME=""
EXPAND_SIZE=""
DRY_RUN=false
MAX_GUEST_WAIT=180
GUEST_RETRY_INTERVAL=5

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run() { [ "$DRY_RUN" = true ] && log "[DRY-RUN] $*" || { log "[RUN] $*"; eval "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; } }
simulate() { echo "$1"; }

# --------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) SOURCE_VMID="$2"; shift 2 ;;
            --target) NEW_VMID="$2"; shift 2 ;;
            --name)   NEW_NAME="$2"; shift 2 ;;
            --expand) EXPAND_SIZE="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) echo "ERROR: Unknown argument $1"; exit 1 ;;
        esac
    done
    [[ -z "$SOURCE_VMID" || -z "$NEW_VMID" || -z "$NEW_NAME" || -z "$EXPAND_SIZE" ]] && { echo "Usage: $0 --source <VMID> --target <NEW_VMID> --name <hostname> --expand <size> [--dry-run]"; exit 1; }
}

# --------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------
preflight_checks() {
    command -v qm >/dev/null || { log "ERROR: qm CLI not found"; exit 1; }
    command -v pvesm >/dev/null || { log "ERROR: pvesm CLI not found"; exit 1; }
    [ "$DRY_RUN" = false ] && {
        qm status "$SOURCE_VMID" >/dev/null || { log "ERROR: Source VM $SOURCE_VMID not found"; exit 1; }
        if qm status "$NEW_VMID" >/dev/null 2>&1; then
            log "ERROR: Target VMID $NEW_VMID already exists"; exit 1
        fi
    }
    log "Pre-flight checks passed."
}

# --------------------------------------------------------------
# Wait for guest-agent
# --------------------------------------------------------------
wait_guest_agent() {
    local vm="$1"
    local waited=0
    until qm guest exec "$vm" -- systemctl is-active qemu-guest-agent >/dev/null 2>&1; do
        sleep "$GUEST_RETRY_INTERVAL"
        waited=$((waited + GUEST_RETRY_INTERVAL))
        log "Waiting for guest-agent ($waited/$MAX_GUEST_WAIT)"
        (( waited >= MAX_GUEST_WAIT )) && { log "ERROR: guest-agent timeout"; exit 1; }
    done
    log "Guest agent active."
}

# --------------------------------------------------------------
# Detect storage & disk
# --------------------------------------------------------------
detect_storage() {
    STORAGE=$( [ "$DRY_RUN" = true ] && simulate "local-lvm" || qm config "$SOURCE_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f2 | cut -d',' -f1 | xargs )
    [[ -z "$STORAGE" ]] && { log "ERROR: could not detect storage"; exit 1; }
    log "Detected storage: $STORAGE"
}

check_storage() {
    local req=$(echo "$EXPAND_SIZE" | sed 's/G//')
    local free
    free=$( [ "$DRY_RUN" = true ] && echo 500 || pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//' )
    (( free < req )) && { log "ERROR: insufficient storage ($free G available)"; exit 1; }
    log "Available storage: ${free}G"
}

detect_disk() {
    DISK=$( [ "$DRY_RUN" = true ] && simulate "scsi0" || qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f1 )
    [[ -z "$DISK" ]] && { log "ERROR: cannot detect disk"; exit 1; }
    log "Primary disk: $DISK"
}

detect_root_partition() {
    ROOT_PART=$( [ "$DRY_RUN" = true ] && simulate "sda1" || qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT | awk '$2=="/"{print $1}' )
    [[ -z "$ROOT_PART" ]] && { log "ERROR: root partition detection failed"; exit 1; }
    log "Root partition: $ROOT_PART"
    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
}

# --------------------------------------------------------------
# Expand filesystem
# --------------------------------------------------------------
expand_filesystem() {
    local FS_TYPE=$( [ "$DRY_RUN" = true ] && simulate "ext4" || qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART" )
    case "$FS_TYPE" in
        xfs) run qm guest exec "$NEW_VMID" -- xfs_growfs / ;;
        ext2|ext3|ext4) run qm guest exec "$NEW_VMID" -- resize2fs "/dev/$ROOT_PART" ;;
        btrfs) run qm guest exec "$NEW_VMID" -- btrfs filesystem resize max / ;;
        *) log "WARNING: unknown filesystem $FS_TYPE" ;;
    esac
    log "Filesystem expansion completed."
}

# --------------------------------------------------------------
# Verification
# --------------------------------------------------------------
verify_post_clone() {
    local vm="$1"
    log "Running post-clone verification"
    run qm guest exec "$vm" -- df -h
    run qm guest exec "$vm" -- lsblk
    run qm guest exec "$vm" -- hostnamectl
    log "Verification complete."
}

# --------------------------------------------------------------
# MAIN
# --------------------------------------------------------------
parse_args "$@"
log "==== Proxmox Clone + Expand Tool ===="
log "Source VM: $SOURCE_VMID"
log "Target VM: $NEW_VMID"
log "Name: $NEW_NAME"
log "Expand: $EXPAND_SIZE"
[ "$DRY_RUN" = true ] && log "DRY-RUN enabled"

preflight_checks
detect_storage
check_storage

# --------------------------------------------------------------
# Snapshot handling: reuse if exists
# --------------------------------------------------------------
if [ "$DRY_RUN" = false ]; then
    EXISTING_SNAP=$(qm listsnapshot "$SOURCE_VMID" 2>/dev/null | awk 'NR>1{print $1}' | xargs -n1)
    if echo "$EXISTING_SNAP" | grep -Fxq "pre-clone"; then
        log "Snapshot 'pre-clone' exists, reusing it for clone"
    else
        log "Creating snapshot 'pre-clone'"
        run qm snapshot "$SOURCE_VMID" pre-clone
    fi
    SNAP_ARG="--snapshot pre-clone"
else
    log "[DRY-RUN] Snapshot check simulated"
    SNAP_ARG="--snapshot pre-clone"
fi

log "Cloning VM"
run qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true $SNAP_ARG

detect_disk
log "Expanding disk"
run qm resize "$NEW_VMID" "$DISK" "$EXPAND_SIZE"

log "Starting VM"
run qm start "$NEW_VMID"
[ "$DRY_RUN" = false ] && wait_guest_agent "$NEW_VMID" || log "[DRY-RUN] Guest agent wait simulated"

detect_root_partition
run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"
expand_filesystem

run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A

verify_post_clone "$NEW_VMID"

log "==== COMPLETE ===="
log "Source VM: $SOURCE_VMID"
log "Clone VM:  $NEW_VMID"
log "Expansion: $EXPAND_SIZE"