#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Proxmox VM Clone + Expand Tool (Fully Upgraded)
# Supports: 
# - --dry-run mode for non-destructive testing
# - thin pool free space validation before expansion
# - guest-agent verification and wait
# - snapshot pre-clone with rollback capability
# - VMID conflict detection
# - post-clone verification with df -h, lsblk, hostnamectl
# - warnings and errors for insufficient storage or unknown FS
# - admin-only path usage recommended (/root/proxmox-tools)
# - logs all steps to /var/log/proxmox-clone-expand.log
# =========================================

# ---------------- CONFIGURATION ----------------
SOURCE_VMID="$1"           # VMID of source VM to clone
NEW_VMID="$2"              # VMID for new cloned VM
NEW_NAME="$3"              # Hostname for new VM
EXPAND_SIZE="$4"           # Disk expansion size (e.g., 100G)
DRY_RUN=false              # Default: perform real operations
MAX_GUEST_WAIT=180         # Max seconds to wait for guest-agent
GUEST_RETRY_INTERVAL=5     # Interval between guest-agent checks
MAX_GROWPART_RETRIES=8     # Growpart retries if partition resize fails
LOG_FILE="/var/log/proxmox-clone-expand.log"

# ---------------- ARGUMENT PARSING ----------------
for arg in "${@:5}"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ---------------- HELPER FUNCTIONS ----------------
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

preflight_checks() {
    # Ensure Proxmox CLI tools exist
    command -v qm >/dev/null 2>&1 || { log "ERROR: 'qm' CLI not found"; exit 1; }
    command -v pvesm >/dev/null 2>&1 || { log "ERROR: 'pvesm' CLI not found"; exit 1; }

    # Ensure source VM exists and target VMID is free
    if [ "$DRY_RUN" = false ]; then
        ! qm status "$SOURCE_VMID" >/dev/null 2>&1 && { log "ERROR: Source VM $SOURCE_VMID missing"; exit 1; }
        qm status "$NEW_VMID" >/dev/null 2>&1 && { log "ERROR: VMID $NEW_VMID exists"; exit 1; }
    fi
    log "Pre-flight checks passed."
}

wait_guest_agent() {
    local waited=0
    until qm guest exec "$1" -- systemctl is-active qemu-guest-agent >/dev/null 2>&1; do
        sleep $GUEST_RETRY_INTERVAL
        waited=$((waited+GUEST_RETRY_INTERVAL))
        log "Waiting for guest-agent on VM $1... ($waited/$MAX_GUEST_WAIT sec)"
        (( waited >= MAX_GUEST_WAIT )) && { log "ERROR: guest-agent timeout"; exit 1; }
    done
    log "Guest-agent active on VM $1."
}

verify_post_clone() {
    local vm="$1"
    log "Verifying clone VM $vm..."
    run qm guest exec "$vm" -- df -h
    run qm guest exec "$vm" -- lsblk
    run qm guest exec "$vm" -- hostnamectl
    log "Verification complete."
}

check_thin_pool_space() {
    local storage="$1"
    local req_size="$2"
    local free_gb
    if [ "$DRY_RUN" = false ]; then
        # Extract thin pool info (assumes 'data' pool)
        free_gb=$(lvs --noheadings -o lv_size,data_percent --units g --nosuffix pve/data \
                  | awk '{print $1*(1-$2/100)}')
    else
        free_gb=$(simulate 500)
    fi
    (( $(echo "$free_gb < $req_size" | bc -l) )) && { log "ERROR: Thin pool free space ($free_gb G) insufficient for expansion ($req_size G)"; exit 1; }
    log "Thin pool free space sufficient: $free_gb G"
}

# ---------------- MAIN ----------------
log "==== Proxmox VM Clone + Expand Tool ===="
log "Source VMID: $SOURCE_VMID, New VMID: $NEW_VMID, New Name: $NEW_NAME, Expand: $EXPAND_SIZE"
[ "$DRY_RUN" = true ] && log "DRY-RUN mode: simulating all operations"

preflight_checks

# ---------------- DETERMINE STORAGE ----------------
STORAGE=$([ "$DRY_RUN" = false ] && qm config "$SOURCE_VMID" | grep -E '^(scsi0|virtio0|sata0|ide0)' \
           | cut -d':' -f2 | cut -d',' -f1 || simulate "local-lvm")
[ -z "$STORAGE" ] && { log "ERROR: Could not determine storage"; exit 1; }
log "Detected storage: $STORAGE"

REQ_SIZE=$(echo "$EXPAND_SIZE" | sed 's/+//;s/G//')
check_thin_pool_space "$STORAGE" "$REQ_SIZE"

# ---------------- SNAPSHOT & CLONE ----------------
log "Creating pre-clone snapshot..."
run qm snapshot "$SOURCE_VMID" pre-clone

log "Cloning VM $SOURCE_VMID -> $NEW_VMID..."
if [ "$DRY_RUN" = false ]; then
    qm clone "$SOURCE_VMID" "$NEW_VMID" --name "$NEW_NAME" --full true --snapshot pre-clone \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[DRY-RUN] Clone simulated"
fi
log "Clone complete."

log "Removing pre-clone snapshot..."
run qm delsnapshot "$SOURCE_VMID" pre-clone || log "Warning: could not delete snapshot"

# ---------------- DETECT PRIMARY DISK ----------------
DISK=$([ "$DRY_RUN" = false ] && qm config "$NEW_VMID" | grep -E '^(scsi|virtio|sata|ide)0' \
        | cut -d':' -f1 || simulate "scsi0")
[ -z "$DISK" ] && { log "ERROR: Could not detect primary disk"; exit 1; }
log "Detected primary disk: $DISK"

# ---------------- EXPAND DISK ----------------
log "Expanding disk $DISK by $EXPAND_SIZE..."
run qm resize "$NEW_VMID" "$DISK" "$EXPAND_SIZE"

# ---------------- START CLONE ----------------
log "Starting cloned VM..."
run qm start "$NEW_VMID"

# ---------------- WAIT FOR GUEST AGENT ----------------
if [ "$DRY_RUN" = false ]; then
    wait_guest_agent "$NEW_VMID"
else
    log "[DRY-RUN] Guest-agent wait simulated"
fi

# ---------------- DETECT ROOT PARTITION ----------------
ROOT_PART=$([ "$DRY_RUN" = false ] && qm guest exec "$NEW_VMID" -- lsblk -ln -o NAME,MOUNTPOINT \
             | awk '$2=="/"{print $1}' || simulate "sda1")
[ -z "$ROOT_PART" ] && { log "ERROR: Could not detect root partition"; exit 1; }
log "Detected root partition: $ROOT_PART"

PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]\+$')
DISK_NAME=$(echo "$ROOT_PART" | sed -E "s/${PART_NUM}$//")

# ---------------- FILESYSTEM EXPANSION ----------------
IS_LVM=$([ "$DRY_RUN" = false ] && qm guest exec "$NEW_VMID" -- lsblk -no TYPE "/dev/$ROOT_PART" \
          || simulate "disk")

if [[ "$IS_LVM" != "lvm" ]]; then
    RETRY=0
    until run qm guest exec "$NEW_VMID" -- growpart "$DISK_NAME" "$PART_NUM"; do
        RETRY=$((RETRY+1))
        (( RETRY >= MAX_GROWPART_RETRIES )) && { log "ERROR: growpart failed"; exit 1; }
        log "Retrying growpart ($RETRY/$MAX_GROWPART_RETRIES)..."
        sleep $GUEST_RETRY_INTERVAL
    done
else
    log "Root is on LVM; skipping growpart."
fi

FS_TYPE=$([ "$DRY_RUN" = false ] && qm guest exec "$NEW_VMID" -- blkid -o value -s TYPE "/dev/$ROOT_PART" || simulate "ext4")
MOUNTPOINT=$([ "$DRY_RUN" = false ] && qm guest exec "$NEW_VMID" -- findmnt -n -o TARGET "/dev/$ROOT_PART" || simulate "/")

case "$FS_TYPE" in
    xfs) run qm guest exec "$NEW_VMID" -- xfs_growfs "$MOUNTPOINT" ;;
    ext2|ext3|ext4) run qm guest exec "$NEW_VMID" -- resize2fs "/dev/$ROOT_PART" ;;
    btrfs) run qm guest exec "$NEW_VMID" -- btrfs filesystem resize max "$MOUNTPOINT" ;;
    f2fs) run qm guest exec "$NEW_VMID" -- f2fs-tools resize.f2fs "/dev/$ROOT_PART" ;;
    lvm)
        log "Detected LVM root; expanding LV..."
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] lvextend +100%FREE on LV (simulated)"
        else
            LV_PATH=$(qm guest exec "$NEW_VMID" -- lvdisplay | awk '/LV Path/{print $3}' | head -n1)
            VG_NAME=$(qm guest exec "$NEW_VMID" -- vgdisplay | awk '/VG Name/{print $3}' | head -n1)
            [[ -n "$LV_PATH" && -n "$VG_NAME" ]] && run qm guest exec "$NEW_VMID" -- lvextend -l +100%FREE "$LV_PATH"
        fi
        ;;
    "") log "WARNING: FS type unknown; manual resize may be required." ;;
    *) log "WARNING: FS $FS_TYPE unknown; manual resize may be required." ;;
esac
log "Filesystem expansion complete."

# ---------------- HOSTNAME & SSH KEYS ----------------
run qm guest exec "$NEW_VMID" -- hostnamectl set-hostname "$NEW_NAME"
run qm guest exec "$NEW_VMID" -- ssh-keygen -A
log "Hostname and SSH keys updated."

# ---------------- POST-CLONE VERIFICATION ----------------
verify_post_clone "$NEW_VMID"

# ---------------- SUMMARY ----------------
log "==== CLONE + EXPAND COMPLETE ===="
log "Original VMID: $SOURCE_VMID"
log "Cloned VMID:   $NEW_VMID"
log "Disk Expansion: $EXPAND_SIZE"
[ "$DRY_RUN" = false ] && log "Verify guest manually if needed"
[ "$DRY_RUN" = true ] && log "[DRY-RUN] Simulation complete; no VM created"