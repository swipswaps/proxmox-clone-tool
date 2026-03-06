Proxmox VM Clone + Expand Tool (Next-Gen Upgrade)
Overview

This repository contains a production-ready Bash automation tool for safely cloning and expanding Proxmox virtual machines.

The script is designed for reliability, auditability, and safe automation, with built-in dry-run simulation and detailed logging.

It works with Proxmox VE 6 / 7 / 8 / 9 and supports common storage backends including:

LVM Thin

LVM

Local directory storage

ZFS-backed disks (filesystem expansion still handled inside the guest)

Features

Dry-run mode (--dry-run) simulates every action before execution.

Full logging of all operations to /var/log/proxmox-clone-expand.log.

Automatic disk detection (scsi0, virtio0, sata0, etc).

Filesystem auto-resize for:

ext2 / ext3 / ext4

XFS

btrfs

LVM logical volumes

Pre-flight checks to prevent unsafe operations.

Guest-agent verification to ensure in-guest resizing works.

Automatic hostname update in the cloned VM.

SSH host key regeneration for security.

Post-clone verification commands included.

Requirements

Before using the tool ensure the following are installed and configured.

1️⃣ Proxmox host requirements

The host must provide:

qm
pvesm
lvs
vgs
pvs

These are installed by default on Proxmox.

2️⃣ Source VM requirements

The source VM must have the QEMU guest agent installed and running.

Inside the VM:

sudo dnf install qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent

Verify from Proxmox host:

qm guest ping <vmid>
Installation

Clone the repository on the Proxmox host.

Recommended location:

/root/proxmox-tools
Step 1 — create tools directory
mkdir -p /root/proxmox-tools
cd /root/proxmox-tools
Step 2 — clone repository
git clone https://github.com/swipswaps/proxmox-clone-tool.git
Step 3 — enter repository
cd proxmox-clone-tool
Step 4 — make script executable
chmod +x proxmox-clone-expand.sh
Usage
Dry-Run Simulation (Recommended)

Always test the operation first.

./proxmox-clone-expand.sh \
  --source 100 \
  --target 101 \
  --name fedora-clone \
  --expand 101G \
  --dry-run
Argument description
Argument	Description
--source	Existing VMID to clone
--target	New VMID for the cloned VM
--name	Hostname assigned to the cloned VM
--expand	Disk size increase (must include unit like G)
--dry-run	Simulates actions without modifying the system

Example values:

--source 100
--target 101
--name fedora-clone
--expand 101G
What dry-run verifies

The script simulates:

Pre-flight safety checks

Storage availability

Snapshot creation

VM cloning

Disk expansion

VM startup

Guest-agent detection

Root partition detection

Filesystem expansion

Hostname configuration

SSH key regeneration

No changes are made to the system.

Running the Actual Clone

Once the dry-run output looks correct:

./proxmox-clone-expand.sh \
  --source 100 \
  --target 101 \
  --name fedora-clone \
  --expand 101G

The script will then automatically:

Create a snapshot of the source VM

Clone the VM

Expand the virtual disk

Start the cloned VM

Wait for the guest agent

Expand the partition

Resize the filesystem

Set the hostname

Regenerate SSH host keys

Run verification commands

Storage Monitoring (Important)

Before expanding disks ensure sufficient space exists.

Check thin-pool usage:

lvs -a -o lv_size,data_percent pve/data

Calculate approximate free space:

tpool=$(lvs --noheadings -o lv_size,data_percent --units g --nosuffix pve/data | awk '{print $1*(1-$2/100)}')
echo "Approx free space in thin pool (GB): $tpool"

Also useful:

pvs
vgs
lvs
Best Practices

Recommended workflow:

Always run --dry-run first

Confirm VMIDs are unused

Verify guest agent is running

Confirm storage space is available

Snapshot important VMs before cloning

Verify filesystem size after clone

Post-Clone Verification

After cloning:

qm guest exec <vmid> -- df -h
qm guest exec <vmid> -- lsblk
qm guest exec <vmid> -- hostnamectl

Verify:

Root filesystem expanded correctly

Hostname updated

Disk layout matches expectations

Troubleshooting
Guest agent not detected

Install and start the service inside the VM:

sudo systemctl enable --now qemu-guest-agent
Disk expansion fails

Check available storage:

lvs
vgs
pvesm status
VMID already exists

Check existing VMs:

qm list

Use a different --target VMID.

Logging

All operations are logged to:

/var/log/proxmox-clone-expand.log

Entries include:

timestamps

dry-run indicators

command output

error messages

Updating the Tool

Update the repository before running automation:

git pull
License

MIT License