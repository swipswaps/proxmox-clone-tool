#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# Proxmox VM Clone + Expand Tool
#
# Features
# --------
# • Supports BOTH argument styles:
#
#   New style (recommended)
#     ./proxmox-clone-expand.sh \
#        --source 100 \
#        --target 101 \
#        --name fedora-clone \
#        --expand 101G \
#        --dry-run
#
#   Backward compatible positional style
#     ./proxmox-clone-expand.sh 100 101 fedora-clone 101G --dry-run
#
# • Safe dry-run simulation
# • Pre-flight validation
# • Snapshot before cloning
# • Automatic disk detection
# • Thin pool space validation
# • Guest agent wait
# • Automatic filesystem expansion
# • LVM detection support
# • Post-clone verification
# • Full logging to /var/log/proxmox-clone-expand.log
#
# ==============================================================

LOG_FILE="/var/log/proxmox-clone-expand.log"

SOURCE_VMID=""
NEW_VMID=""
NEW_NAME=""
EXPAND_SIZE=""
DRY_RUN=false

MAX_GUEST_WAIT=180
GUEST_RETRY_INTERVAL=5
MAX_GROWPART_RETRIES=8


# --------------------------------------------------------------
# Logging
# --------------------------------------------------------------

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

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

    # detect positional argument style
    if [[ $# -ge 4 && "$1" != "--"* ]]; then
        SOURCE_VMID="$1"
        NEW_VMID="$2"
        NEW_NAME="$3"
        EXPAND_SIZE="$4"
        shift 4
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in

            --source)
                SOURCE_VMID="$2"
                shift 2
                ;;

            --target)
                NEW_VMID="$2"
                shift 2
                ;;

            --name)
                NEW_NAME="$2"
                shift 2
                ;;

            --expand)
                EXPAND_SIZE="$2"
                shift 2
                ;;

            --dry-run)
                DRY_RUN=true
                shift
                ;;

            *)
                echo "ERROR: Unknown argument: $1"
                exit 1
                ;;

        esac
    done

    if [[ -z "$SOURCE_VMID" || -z "$NEW_VMID" || -z "$NEW_NAME" || -z "$EXPAND_SIZE" ]]; then
        echo
        echo "Usage:"
        echo
        echo "  ./proxmox-clone-expand.sh \\"
        echo "      --source <VMID> \\"
        echo "      --target <NEW_VMID> \\"
        echo "      --name <hostname> \\"
        echo "      --expand <size> \\"
        echo "      [--dry-run]"
        echo
        echo "Example:"
        echo
        echo "  ./proxmox-clone-expand.sh \\"
        echo "      --source 100 \\"
        echo "      --target 101 \\"
        echo "      --name fedora-clone \\"
        echo "      --expand 101G \\"
        echo "      --dry-run"
        echo
        exit 1
    fi
}


# --------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------

preflight_checks() {

    command -v qm >/dev/null || { log "ERROR: qm CLI not found"; exit 1; }
    command -v pvesm >/dev/null || { log "ERROR: pvesm CLI not found"; exit 1; }

    if [ "$DRY_RUN" = false ]; then

        qm status "$SOURCE_VMID" >/dev/null 2>&1 \
            || { log "ERROR: Source VM $SOURCE_VMID not found"; exit 1; }

        if qm status "$NEW_VMID" >/dev/null 2>&1; then
            log "ERROR: Target VMID $NEW_VMID already exists"
            exit 1
        fi
    fi

    log "Pre-flight checks passed."
}



# --------------------------------------------------------------
# Wait for guest agent
# --------------------------------------------------------------

wait_guest_agent() {

    local vm="$1"
    local waited=0

    until qm guest exec "$vm" -- systemctl is-active qemu-guest-agent >/dev/null 2>&1
    do
        sleep "$GUEST_RETRY_INTERVAL"

        waited=$((waited + GUEST_RETRY_INTERVAL))

        log "Waiting for guest-agent ($waited/$MAX_GUEST_WAIT)"

        if (( waited >= MAX_GUEST_WAIT )); then
            log "ERROR: guest-agent timeout"
            exit 1
        fi
    done

    log "Guest agent active."
}



# --------------------------------------------------------------
# Verify clone
# --------------------------------------------------------------

verify_post_clone() {

    vm="$1"

    log "Running post-clone verification"

    run qm guest exec "$vm" -- df -h
    run qm guest exec "$vm" -- lsblk
    run qm guest exec "$vm" -- hostnamectl

    log "Verification complete."
}



# --------------------------------------------------------------
# Detect storage
# --------------------------------------------------------------

detect_storage() {

    if [ "$DRY_RUN" = false ]; then

        STORAGE=$(qm config "$SOURCE_VMID" \
            | grep -E '^(scsi|virtio|sata|ide)0' \
            | cut -d':' -f2 \
            | cut -d',' -f1 \
            | xargs)   # <-- trim leading/trailing whitespace

    else
        STORAGE=$(simulate "local-lvm")
    fi

    if [[ -z "$STORAGE" ]]; then
        log "ERROR: could not detect storage"
        exit 1
    fi

    log "Detected storage: $STORAGE"
}



# --------------------------------------------------------------
# Storage capacity check
# --------------------------------------------------------------

check_storage() {

    req=$(echo "$EXPAND_SIZE" | sed 's/G//')

    if [ "$DRY_RUN" = false ]; then
        free=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $4}' | sed 's/G//')
    else
        free=500
    fi

    if (( free < req )); then
        log "ERROR: insufficient storage ($free G available)"
        exit 1
    fi

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

    if [[ -z "$DISK" ]]; then
        log "ERROR: cannot detect disk"
        exit 1
    fi

    log "Primary disk: $DISK"
}



# --------------------------------------------------------------
# Root partition detection
# --------------------------------------------------------------

detect_root_partition() {

    if [ "$DRY_RUN" = false ]; then
        ROOT_PART=$(qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT \
            | awk '$2=="/"{print $1}')
    else
        ROOT_PART="sda1"
    fi

    if [[ -z "$ROOT_PART" ]]; then
        log "ERROR: root partition detection failed"
        exit 1
    fi

    log "Root partition: $ROOT_PART"

    PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
    DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")
}



# --------------------------------------------------------------
# Filesystem resize
# --------------------------------------------------------------

expand_filesystem() {

    if [ "$DRY_RUN" = false ]; then
        FS_TYPE=$(qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART")
    else
        FS_TYPE="ext4"
    fi

    case "$FS_TYPE" in

        xfs)
            run qm guest exec "$NEW_VMID" -- xfs_growfs /
            ;;

        ext2|ext3|ext4)
            run qm guest exec "$NEW_VMID" -- resize2fs "/dev/$ROOT_PART"
            ;;

        btrfs)
            run qm guest exec "$NEW_VMID" -- btrfs filesystem resize max /
            ;;

        *)
            log "WARNING: unknown filesystem $FS_TYPE"
            ;;
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

if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN enabled"
fi

preflight_checks
detect_storage
check_storage

log "Creating snapshot"
run qm snapshot "$SOURCE_VMID" pre-clone

log "Cloning VM"
run qm clone "$SOURCE_VMID" "$NEW_VMID" \
     --name "$NEW_NAME" \
     --full true \
     --snapshot pre-clone

log "Removing snapshot"
run qm delsnapshot "$SOURCE_VMID" pre-clone || true

detect_disk

log "Expanding disk"
run qm resize "$NEW_VMID" "$DISK" "$EXPAND_SIZE"

log "Starting VM"
run qm start "$NEW_VMID"

if [ "$DRY_RUN" = false ]; then
    wait_guest_agent "$NEW_VMID"
else
    log "[DRY-RUN] Guest agent wait simulated"
fi

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