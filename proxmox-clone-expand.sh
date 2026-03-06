#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# Proxmox VM Clone + Expand Tool (PRF-Compliant, Fully Upgraded)
# Features:
# • Full dry-run output for every step
# • Logic checks at every stage
# • Snapshot reuse / creation
# • Storage and disk detection
# • Partition growth and filesystem resize
# • Guest-agent check
# • Post-clone verification
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
# Logging & Command Wrappers
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
simulate() { log "[SIMULATE] $*"; }

# --------------------------------------------------------------
# Argument Parsing
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
    [[ -z "$SOURCE_VMID" || -z "$NEW_VMID" || -z "$NEW_NAME" || -z "$EXPAND_SIZE" ]] && {
        log "ERROR: Missing required arguments"; exit 1
    }
    log "Arguments OK: source=$SOURCE_VMID, target=$NEW_VMID, name=$NEW_NAME, expand=$EXPAND_SIZE, dry-run=$DRY_RUN"
}

# --------------------------------------------------------------
# Pre-flight Checks
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
# Guest Agent Wait
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
# Storage & Disk Detection
# --------------------------------------------------------------
detect_storage() {
    log "Detecting storage for VM $SOURCE_VMID..."
    if [ "$DRY_RUN" = true ]; then
        STORAGE=$(simulate "local-lvm")
    else
        STORAGE=$(qm config "$SOURCE_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f2 | cut -d',' -f1 | xargs)
    fi
    [[ -z "$STORAGE" ]] && { log "ERROR: could not detect storage"; exit 1; }
    log "Detected storage: $STORAGE"
}

check_storage() {
    log "Checking available storage..."
    local req=$(echo "$EXPAND_SIZE" | sed 's/G//')
    local free
    if [ "$DRY_RUN" = true ]; then
        free=$(simulate "500")
    else
        free=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//')
    fi
    (( free < req )) && { log "ERROR: insufficient storage ($free G available)"; exit 1; }
    log "Storage sufficient: $free G available"
}

detect_disk() {
    log "Detecting primary disk for VM $NEW_VMID..."
    if [ "$DRY_RUN" = true ]; then
        DISK=$(simulate "scsi0")
    else
        DISK=$(qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' | cut -d':' -f1)
    fi
    [[ -z "$DISK" ]] && { log "ERROR: cannot detect disk"; exit 1; }
    log "Primary disk: $DISK"
}

detect_root_partition() {
    log "Detecting root partition on VM $NEW_VMID..."
    if [ "$DRY_RUN" = true ]; then
        ROOT_PART=$(simulate "sda1")
    else
        ROOT_PART=$(qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT | awk '$2=="/"{print $1}')
    fi
    [[ -z "$ROOT_PART" ]] && { log "ERROR: root partition detection failed"; exit 1; }
    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
    log "Root partition: $ROOT_PART (Disk: $DISK_NAME, Partition Number: $PART_NUM)"
}

# --------------------------------------------------------------
# Expand Filesystem
# --------------------------------------------------------------
expand_filesystem() {
    log "Expanding filesystem on /dev/$ROOT_PART..."
    local FS_TYPE
    if [ "$DRY_RUN" = true ]; then
        FS_TYPE=$(simulate "ext4")
    else
        FS_TYPE=$(qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART")
    fi
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
# Post-Clone Verification
# --------------------------------------------------------------
verify_post_clone() {
    local vm="$1"
    log "Running post-clone verification..."
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

# Snapshot handling
if [ "$DRY_RUN" = false ]; then
    EXISTING_SNAP=$(qm listsnapshot "$SOURCE_VMID" 2>/dev/null | awk 'NR>1{print $1}' | xargs -n1)
    if echo "$EXISTING_SNAP" | grep -Fxq "pre-clone"; then
        log "Snapshot 'pre-clone' exists, reusing it"
    else
        log "Creating snapshot 'pre-clone'"
        run qm snapshot "$SOURCE_VMID" pre-clone
    fi
    SNAP_ARG="--snapshot pre-clone"
else
    SNAP_ARG="--snapshot pre-clone"
    log "[DRY-RUN] Snapshot handling simulated"
fi

# Clone VM
log "Cloning VM $SOURCE_VMID to $NEW_VMID..."
run qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true $SNAP_ARG

# Wait until VM exists
log "Waiting for VM $NEW_VMID to appear..."
waited=0
until [ "$DRY_RUN" = true ] || qm status "$NEW_VMID" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    log "Waiting for VM ($waited sec)"
    (( waited > 60 )) && { log "ERROR: Cloned VM did not appear"; exit 1; }
done
log "VM $NEW_VMID detected (or simulated in dry-run)"

# Start VM
log "Starting VM $NEW_VMID..."
run qm start "$NEW_VMID"

# Wait for guest-agent
[ "$DRY_RUN" = false ] && wait_guest_agent "$NEW_VMID" || log "[DRY-RUN] Guest agent wait simulated"

# Detect disk & root partition
detect_disk
detect_root_partition

# Grow partition and expand filesystem
log "Growing partition..."
run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"
expand_filesystem

# Hostname and SSH setup
log "Setting hostname and generating SSH keys..."
run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A

# Verification
verify_post_clone "$NEW_VMID"

log "==== COMPLETE ===="
log "Source VM: $SOURCE_VMID"
log "Clone VM:  $NEW_VMID"
log "Expansion: $EXPAND_SIZE"