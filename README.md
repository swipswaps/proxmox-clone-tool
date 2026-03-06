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
# Create snapshot (optional but safest)
qm snapshot <source-vmid> pre-clone