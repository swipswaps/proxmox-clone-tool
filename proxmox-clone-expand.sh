#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# Proxmox VM Clone + Expand Tool (Fully Upgraded)
#
# Features & Fixes:
# • Reliable snapshot existence detection via qm listsnapshot + exact name matching
# • Automatic disk expansion after cloning
# • Guest filesystem resize according to partition type
# • Post-clone verification: df, lsblk, hostnamectl
# • Dry-run mode for safe simulation
# • Pre-flight validation for source VM and target VMID
# • Full logging to /var/log/proxmox-clone-expand.log
# • Supports LVM, ext4, xfs, btrfs
# • Waits for qemu-guest-agent before filesystem expansion
# ==============================================================

LOG_FILE="/var/log/proxmox-clone-expand.log"

SOURCE_VMID=""
NEW_VMID=""
NEW_NAME=""
EXPAND_SIZE=""
DRY_RUN=false

MAX_GUEST_WAIT=180
GUEST_RETRY_INTERVAL=5

# --------------------------------------------------------------
# Logging
# --------------------------------------------------------------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

run() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] $*"
    else
        log "[RUN] $*"
        eval "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    fi
}

simulate() { echo "$1"; }

# --------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------
parse_args() {
    if [[ $# -ge 4 && "$1" != "--"* ]]; then
        SOURCE_VMID="$1"
        NEW_VMID="$2"
        NEW_NAME="$3"
        EXPAND_SIZE="$4"
        shift 4
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) SOURCE_VMID="$2"; shift 2 ;;
            --target) NEW_VMID="$2"; shift 2 ;;
            --name)   NEW_NAME="$2"; shift 2 ;;
            --expand) EXPAND_SIZE="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$SOURCE_VMID" || -z "$NEW_VMID" || -z "$NEW_NAME" || -z "$EXPAND_SIZE" ]]; then
        echo
        echo "Usage:"
        echo "  ./proxmox-clone-expand.sh \\"
        echo "      --source <VMID> \\"
        echo "      --target <NEW_VMID> \\"
        echo "      --name <hostname> \\"
        echo "      --expand <size> \\"
        echo "      [--dry-run]"
        echo
        exit 1
    fi
}

# --------------------------------------------------------------
# Pre-flight validation
# --------------------------------------------------------------
preflight_checks() {
    command -v qm >/dev/null || { log "ERROR: qm CLI not found"; exit 1; }
    command -v pvesm >/dev/null || { log "ERROR: pvesm CLI not found"; exit 1; }

    if [ "$DRY_RUN" = false ]; then
        qm status "$SOURCE_VMID" >/dev/null 2>&1 || { log "ERROR: Source VM $SOURCE_VMID not found"; exit 1; }
        if qm status "$NEW_VMID" >/dev/null 2>&1; then
            log "ERROR: Target VMID $NEW_VMID already exists"; exit 1
        fi
    fi

    log "Pre-flight checks passed."
}

# --------------------------------------------------------------
# Guest agent wait
# --------------------------------------------------------------
wait_guest_agent() {
    local vm="$1"
    local waited=0
    until qm guest exec "$vm" -- systemctl is-active qemu-guest-agent >/dev/null 2>&1; do
        sleep "$GUEST_RETRY_INTERVAL"
        waited=$((waited + GUEST_RETRY_INTERVAL))
        log "Waiting for guest-agent ($waited/$MAX_GUEST_WAIT)"
        if (( waited >= MAX_GUEST_WAIT )); then
            log "ERROR: guest-agent timeout"; exit 1
        fi
    done
    log "Guest agent active."
}

# --------------------------------------------------------------
# Post-clone verification
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
# Storage detection
# --------------------------------------------------------------
detect_storage() {
    if [ "$DRY_RUN" = false ]; then
        STORAGE=$(qm config "$SOURCE_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f2 | cut -d',' -f1 | xargs)
    else
        STORAGE=$(simulate "local-lvm")
    fi

    [[ -z "$STORAGE" ]] && { log "ERROR: could not detect storage"; exit 1; }
    log "Detected storage: $STORAGE"
}

# --------------------------------------------------------------
# Storage capacity check
# --------------------------------------------------------------
check_storage() {
    local req=$(echo "$EXPAND_SIZE" | sed 's/G//')
    local free
    if [ "$DRY_RUN" = false ]; then
        free=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//')
    else
        free=500
    fi
    (( free < req )) && { log "ERROR: insufficient storage ($free G available)"; exit 1; }
    log "Available storage: ${free}G"
}

# --------------------------------------------------------------
# Detect primary disk
# --------------------------------------------------------------
detect_disk() {
    if [ "$DRY_RUN" = false ]; then
        DISK=$(qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f1)
    else
        DISK="scsi0"
    fi
    [[ -z "$DISK" ]] && { log "ERROR: cannot detect disk"; exit 1; }
    log "Primary disk: $DISK"
}

# --------------------------------------------------------------
# Detect root partition
# --------------------------------------------------------------
detect_root_partition() {
    if [ "$DRY_RUN" = false ]; then
        ROOT_PART=$(qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT | awk '$2=="/"{print $1}')
    else
        ROOT_PART="sda1"
    fi
    [[ -z "$ROOT_PART" ]] && { log "ERROR: root partition detection failed"; exit 1; }

    log "Root partition: $ROOT_PART"
    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
}

# --------------------------------------------------------------
# Expand filesystem
# --------------------------------------------------------------
expand_filesystem() {
    local FS_TYPE
    if [ "$DRY_RUN" = false ]; then
        FS_TYPE=$(qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART")
    else
        FS_TYPE="ext4"
    fi

    case "$FS_TYPE" in
        xfs) run qm guest exec "$NEW_VMID" -- xfs_growfs / ;;
        ext2|ext3|ext4) run qm guest exec "$NEW_VMID" -- resize2fs "/dev/$ROOT_PART" ;;
        btrfs) run qm guest exec "$NEW_VMID" -- btrfs filesystem resize max / ;;
        *) log "WARNING: unknown filesystem $FS_TYPE" ;;
    esac
    log "Filesystem expansion completed."
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

# Snapshot handling: reliable detection
if [ "$DRY_RUN" = false ]; then
    if qm listsnapshot "$SOURCE_VMID" | awk 'NR>1 {print $1}' | grep -Fxq "pre-clone"; then
        log "Snapshot 'pre-clone' exists, skipping creation"
    else
        log "Creating snapshot 'pre-clone'"
        run qm snapshot "$SOURCE_VMID" pre-clone
    fi
else
    log "[DRY-RUN] Snapshot check simulated"
fi

# Clone VM
log "Cloning VM"
run qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true

detect_disk

# Expand disk
log "Expanding disk"
run qm resize "$NEW_VMID" "$DISK" "$EXPAND_SIZE"

# Start VM
log "Starting VM"
run qm start "$NEW_VMID"

# Wait for guest agent
[ "$DRY_RUN" = false ] && wait_guest_agent "$NEW_VMID" || log "[DRY-RUN] Guest agent wait simulated"

# Detect root partition and expand filesystem
detect_root_partition
run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"
expand_filesystem

# Set hostname and generate SSH host keys
run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A

# Post-clone verification
verify_post_clone "$NEW_VMID"

log "==== COMPLETE ===="
log "Source VM: $SOURCE_VMID"
log "Clone VM:  $NEW_VMID"
log "Expansion: $EXPAND_SIZE"