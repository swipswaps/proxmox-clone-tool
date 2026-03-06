# Proxmox VM Clone + Expand Tool (Next-Gen Upgrade)

## Overview

This repository contains a **production-ready Bash tool** for cloning and expanding Proxmox VMs with full dry-run simulation, verbose logging, and real-time feedback. The script is designed for reliability, automation, and auditability.

**Key features:**

- Full dry-run simulation (`--dry-run`) to verify actions without making changes.
- Logs all actions, progress, and errors to `/var/log/proxmox-clone-expand.log`.
- Detects LVM vs non-LVM root partitions and resizes filesystems safely.
- Automates hostname, SSH key, and MAC address updates after cloning.
- Pre-flight checks for VM existence, storage availability, and guest-agent readiness.
- Supports multiple disk types (`scsi0`, `virtio0`, `sata0`) automatically.
- Provides clear instructions and guidance for expanding Fedora/XFS and ext4 filesystems.

---

## Prerequisites

Before using the script:

1. **Proxmox VE host** with `qm` and `pvesm` CLI installed.
2. **Source VM** must have `qemu-guest-agent` installed and active.
3. **Storage space**: Ensure sufficient free space in the target storage pool for the clone and expansion.
4. **Bash 4+** with `pipefail` support.
5. **Optional but recommended**: Snapshot of source VM to prevent filesystem inconsistencies.

```bash
# Make the script executable
chmod +x proxmox-clone-expand.sh

# Create snapshot (optional but safest)
qm snapshot <source-vmid> pre-clone
Usage
Dry-run Simulation (Safe)

This mode verifies all actions without making changes. Logs are saved for review.

./proxmox-clone-expand.sh <source-vmid> <new-vmid> "<new-vm-name>" +<size>G --dry-run

# Example: simulate cloning VM 101 to VM 102 with +200G expansion
./proxmox-clone-expand.sh 101 102 "New-VM" +200G --dry-run
Live Clone + Expand

Once verified, run the script to perform the actual clone and expansion.

./proxmox-clone-expand.sh <source-vmid> <new-vmid> "<new-vm-name>" +<size>G

# Example: clone VM 101 to VM 102 with +200G expansion
./proxmox-clone-expand.sh 101 102 "New-VM" +200G
Post-Clone Verification

After the clone:

Confirm the VM boots successfully.

Check that the filesystem expansion completed as expected:

df -h
lsblk

Verify SSH access and hostname updates:

ssh root@<new-vm-ip>
hostname

Confirm that the Proxmox VM configuration reflects correct disk sizes and MAC addresses:

qm config <new-vmid>
Notes & Best Practices

Always run the script in --dry-run mode first.

Snapshots of source VMs are highly recommended to avoid filesystem inconsistencies.

The script supports common disk types (scsi0, virtio0, sata0) and detects LVM vs non-LVM automatically.

Logs at /var/log/proxmox-clone-expand.log include verbose step-by-step actions for auditing and troubleshooting.

Ensure sufficient free space in the target storage pool to accommodate the expanded disk.

Support & References

This tool was developed following best practices observed in:

Proxmox official forums: https://forum.proxmox.com/

Popular GitHub repositories for VM cloning and automation

Reputable user guides and articles on LVM and filesystem expansion