#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# Proxmox VM Clone + Expand Tool (Fully Audit-Informed, Hardened)
# Features:
# - VM config & guest-agent readiness
# - Storage & filesystem checks
# - Timestamped snapshot
# - Dry-run fully supported
# - Full logic checks, retries, and detailed logging
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

# --------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------
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

# --------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------
preflight_checks() {
    log "Running pre-flight checks..."
    command -v qm >/dev/null || { log "ERROR: qm CLI not found"; exit 1; }
    command -v pvesm >/dev/null || { log "ERROR: pvesm CLI not found"; exit 1; }
    if [ "$DRY_RUN" = false ]; then
        qm status "$SOURCE_VMID" >/dev/null || { log "ERROR: Source VM $SOURCE_VMID not found"; exit 1; }
        if qm status "$NEW_VMID" >/dev/null 2>&1; then
            log "ERROR: Target VMID $NEW_VMID already exists"; exit 1
        fi
    fi
    log "Pre-flight checks passed."
}

# --------------------------------------------------------------
# Wait for guest-agent readiness
# --------------------------------------------------------------
wait_guest_agent() {
    local vm="$1"
    log "Checking guest-agent on VM $vm..."
    local waited=0
    until qm guest exec "$vm" -- systemctl is-active qemu-guest-agent >/dev/null 2>&1; do
        sleep "$GUEST_RETRY_INTERVAL"
        waited=$((waited + GUEST_RETRY_INTERVAL))
        log "Waiting for guest-agent ($waited/$MAX_GUEST_WAIT)"
        (( waited >= MAX_GUEST_WAIT )) && { log "ERROR: guest-agent timeout"; exit 1; }
    done
    log "Guest agent active on VM $vm."
}

# --------------------------------------------------------------
# Storage detection and check
# --------------------------------------------------------------
detect_storage() {
    log "Detecting storage for VM $SOURCE_VMID..."
    STORAGE=$( [ "$DRY_RUN" = true ] && echo "local-lvm" || qm config "$SOURCE_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f2 | cut -d',' -f1 | xargs )
    [[ -z "$STORAGE" ]] && { log "ERROR: could not detect storage"; exit 1; }
    log "Detected storage: $STORAGE"
}

check_storage() {
    log "Checking available storage on $STORAGE..."
    local req=$(echo "$EXPAND_SIZE" | sed 's/G//')
    local free
    free=$( [ "$DRY_RUN" = true ] && echo "500" || pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//' )
    if ! [[ "$free" =~ ^[0-9]+$ ]]; then
        log "ERROR: Storage check failed, non-numeric free space: $free"; exit 1
    fi
    (( free < req )) && { log "ERROR: insufficient storage ($free G available, $req G required)"; exit 1; }
    log "Storage sufficient: $free G available"
}

# --------------------------------------------------------------
# Snapshot creation with timestamp
# --------------------------------------------------------------
prepare_snapshot() {
    local vm="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local snap_name="pre-clone-$timestamp"
    log "Snapshot name set to: $snap_name"
    if [ "$DRY_RUN" = false ]; then
        run qm snapshot "$vm" "$snap_name"
    else
        log "[DRY-RUN] Snapshot handling simulated with name $snap_name"
    fi
    SNAP_NAME="$snap_name"
}

# --------------------------------------------------------------
# Wait for VM config after clone
# --------------------------------------------------------------
wait_vm_config() {
    log "Waiting for VM $NEW_VMID config..."
    local tries=0
    while [ "$tries" -lt 20 ]; do
        if [ "$DRY_RUN" = true ] || [ -f "/etc/pve/qemu-server/${NEW_VMID}.conf" ]; then
            log "VM $NEW_VMID config detected."
            return
        fi
        log "VM config not found yet, retrying..."
        sleep 2
        tries=$((tries+1))
    done
    log "ERROR: VM config for $NEW_VMID not found"; exit 1
}

# --------------------------------------------------------------
# Disk and root partition detection
# --------------------------------------------------------------
detect_disk() {
    log "Detecting primary disk for VM $NEW_VMID..."
    local tries=0
    while [ "$tries" -lt 20 ]; do
        DISK=$( [ "$DRY_RUN" = true ] && echo "scsi0" || qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f1 )
        [[ -n "$DISK" ]] && { log "Primary disk detected: $DISK"; return; }
        log "Disk not found yet, retrying..."
        sleep 2
        tries=$((tries+1))
    done
    log "ERROR: cannot detect disk after multiple retries"; exit 1
}

detect_root_partition() {
    log "Detecting root partition for VM $NEW_VMID..."
    wait_guest_agent "$NEW_VMID"
    ROOT_PART=$( [ "$DRY_RUN" = true ] && echo "sda1" || qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT | awk '$2=="/"{print $1}' )
    [[ -z "$ROOT_PART" ]] && { log "ERROR: root partition detection failed"; exit 1; }
    log "Root partition detected: $ROOT_PART"
    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
    log "Disk=$DISK_NAME, Partition Number=$PART_NUM"
}

# --------------------------------------------------------------
# Expand filesystem
# --------------------------------------------------------------
expand_filesystem() {
    log "Expanding filesystem on /dev/$ROOT_PART..."
    local FS_TYPE=$( [ "$DRY_RUN" = true ] && echo "ext4" || qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART" )
    log "Detected filesystem type: $FS_TYPE"
    case "$FS_TYPE" in
        xfs) run qm guest exec "$NEW_VMID" -- xfs_growfs / ;;
        ext2|ext3|ext4) run qm guest exec "$NEW_VMID" -- resize2fs "/dev/$ROOT_PART" ;;
        btrfs) run qm guest exec "$NEW_VMID" -- btrfs filesystem resize max / ;;
        *) log "WARNING: unknown filesystem $FS_TYPE" ;;
    esac
    log "Filesystem expansion step completed."
}

# --------------------------------------------------------------
# Post-clone verification
# --------------------------------------------------------------
verify_post_clone() {
    local vm="$1"
    log "Running post-clone verification on VM $vm..."
    run qm guest exec "$vm" -- df -h
    run qm guest exec "$vm" -- lsblk
    run qm guest exec "$vm" -- hostnamectl
    log "Post-clone verification complete."
}

# --------------------------------------------------------------
# MAIN
# --------------------------------------------------------------
parse_args "$@"

log "==== START Proxmox Clone + Expand ===="
log "Source VM: $SOURCE_VMID"
log "Target VM: $NEW_VMID"
log "Name: $NEW_NAME"
log "Expand: $EXPAND_SIZE"
[ "$DRY_RUN" = true ] && log "DRY-RUN mode enabled"

preflight_checks
detect_storage
check_storage

prepare_snapshot "$SOURCE_VMID"

log "Cloning VM $SOURCE_VMID to $NEW_VMID..."
run qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true --snapshot "$SNAP_NAME"

wait_vm_config

log "Starting VM $NEW_VMID..."
run qm start "$NEW_VMID"

detect_disk
detect_root_partition

log "Growing partition..."
run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"
expand_filesystem

log "Setting hostname and generating SSH keys..."
run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A

verify_post_clone "$NEW_VMID"

log "==== COMPLETE ===="
log "Source VM: $SOURCE_VMID"
log "Clone VM:  $NEW_VMID"
log "Expansion: $EXPAND_SIZE"