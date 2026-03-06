# Proxmox VM Clone + Expand Tool (Next-Gen Upgrade)

## Overview

This repository contains a **production-ready Bash tool** for cloning and expanding Proxmox VMs with full dry-run simulation, verbose logging, and real-time feedback. The script is designed for reliability, automation, and auditability.

- Fully supports dry-run mode (`--dry-run`) for safe testing.
- Logs all actions, progress, events, and errors to `/var/log/proxmox-clone-expand.log`.
- Detects LVM vs non-LVM root partitions and resizes filesystems safely.
- Automates hostname and SSH key updates after cloning.
- Includes pre-flight checks, retries for guest-agent readiness, and post-clone verification.

---

## User Guide

### Prerequisites

- Proxmox VE host with `qm` and `pvesm` CLI installed.
- Source VM must have `qemu-guest-agent` installed and active.
- Sufficient storage in the target storage pool for disk expansion.
- Bash 4+ with `pipefail` support.

---

### Usage

```bash
# Dry-run simulation (safe, logs all actions)
./proxmox-clone-expand.sh <source-vmid> <new-vmid> "<new-vm-name>" +<size>G --dry-run

# Example: simulate cloning VM 101 to VM 102 with +200G expansion
./proxmox-clone-expand.sh 101 102 "New-VM" +200G --dry-run

# Live clone + expand
./proxmox-clone-expand.sh 101 102 "New-VM" +200G