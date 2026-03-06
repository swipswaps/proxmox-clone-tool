# Proxmox VM Clone + Expand Tool (Next-Gen Upgrade)

## Overview

This repository contains a **production-ready Bash tool** for cloning and expanding Proxmox VMs with full dry-run simulation, verbose logging, and real-time feedback. The script is designed for **reliability, automation, and auditability**, fully compatible with Proxmox VE 6+ and 7+, using thin pools, LVM, or standard disks.

**Key features:**

- Full dry-run simulation (`--dry-run`) to verify actions without making changes.
- Logs all actions, progress, and errors to `/var/log/proxmox-clone-expand.log`.
- Detects LVM vs non-LVM root partitions and safely resizes filesystems.
- Supports multiple disk types (`scsi0`, `virtio0`, `sata0`) automatically.
- Automates hostname, SSH key regeneration, and MAC address updates.
- Pre-flight checks for VM existence, storage space, and guest-agent readiness.
- Provides clear instructions for expanding Fedora/XFS and ext4 filesystems.
- Handles thin pool usage and provides approximate free space for safe expansion.
- Post-clone verification commands included for auditing.

---

## Prerequisites

Before using the script:

1. **Proxmox VE host** with `qm` and `pvesm` CLI installed.
2. **Source VM** must have `qemu-guest-agent` installed and running.
3. **Storage space**: Ensure sufficient free space in the target storage pool, especially when using thin pools.
4. **Bash 4+** with `pipefail` support.
5. **Optional but recommended**: Snapshot of source VM to prevent filesystem inconsistencies.

```bash
# Create snapshot (optional but safest)
qm snapshot <source-vmid> pre-clone

Recommended location for cloning repository on Proxmox host:

# Example: /root/proxmox-tools for admin scripts
mkdir -p /root/proxmox-tools
cd /root/proxmox-tools
git clone https://github.com/swipswaps/proxmox-clone-tool.git
cd proxmox-clone-tool
chmod +x proxmox-clone-expand.sh
Usage
Dry-run simulation

Before performing any real operation, verify the script behavior:

./proxmox-clone-expand.sh --source 100 --target 101 --expand 101 --dry-run

--source 100 → existing VMID to clone

--target 101 → new VMID for cloned VM

--expand 101 → size in GB to expand the primary disk

--dry-run → simulates all operations without creating the VM

Expected output will display:

Pre-flight checks

Available storage and thin pool free space

Snapshot creation (simulated)

Clone plan and disk expansion plan

Guest-agent wait simulation

Root partition detection and filesystem resize commands

Hostname and SSH key update simulation

Verification steps (simulated)

Live-run cloning

Once the dry-run is verified:

./proxmox-clone-expand.sh --source 100 --target 101 --expand 101

Omitting --dry-run executes all commands.

The script will automatically:

Take a pre-clone snapshot

Clone the VM to the target VMID

Expand the primary disk

Start the cloned VM

Wait for the guest agent

Grow the root partition and resize the filesystem

Update hostname and regenerate SSH host keys

Provide verification output

Disk and Thin Pool Monitoring

Check thin pool usage to ensure enough free space:

# Approximate free space in GB
tpool=$(lvs --noheadings -o lv_size,data_percent --units g --nosuffix pve/data | awk '{print $1*(1-$2/100)}')
echo "Approx free space in thin pool (GB): $tpool"

Do not exceed the available free space when expanding disks.

lvs, vgs, and pvs are useful for monitoring LVM thin pool usage:

pvs      # Physical volume stats
vgs      # Volume group stats
lvs -a -o +seg_monitor  # All logical volumes with monitoring info
Best Practices

Always run --dry-run first to ensure no unintended changes.

Ensure thin pool free space is greater than the planned disk expansion.

Verify that source VM guest-agent is running (systemctl status qemu-guest-agent inside the VM).

Snapshot the source VM before cloning to allow rollback.

Confirm VMIDs do not conflict with existing VMs.

Keep repository and script updated with git pull before cloning new VMs.

Use /root/proxmox-tools or another admin-only directory for scripts to avoid accidental modification.

Always check df -h and lsblk after clone expansion to confirm filesystem size matches expectations.

Post-clone Verification

After cloning and expansion:

qm guest exec <new-vmid> -- df -h
qm guest exec <new-vmid> -- lsblk
qm guest exec <new-vmid> -- hostnamectl

Ensure that the root filesystem shows the expanded size.

Confirm the cloned VM hostname is updated.

Verify SSH keys have been regenerated for security.

Troubleshooting

Disk expansion fails → check thin pool free space or adjust --expand size.

Guest-agent not detected → install and start qemu-guest-agent in source VM.

VMID conflicts → ensure --target VMID does not exist.

Filesystem resize errors → verify root partition type (ext4 or xfs) matches the script logic.

Logging

All operations are logged to:

/var/log/proxmox-clone-expand.log

Dry-run actions are clearly marked [DRY-RUN].

Errors are reported with timestamps for easy audit.

Contributing

Fork the repository, make your changes, and submit pull requests.

Ensure all modifications preserve dry-run functionality.

Do not remove or simplify logging, verification, or thin-pool checks.

License

This repository is released under the MIT License.