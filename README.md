# proxmox_pve_scripts
Scripts to tune and replicate Proxmox PVE hosts

# [zfs_replicate.sh](/zfs_replicate/README.md)

Replication of ZFS datasets belonging to a Proxmox VE guest (VM or LXC
container) from a local Proxmox host to a remote Proxmox host.
Script inspired by my colleague Patrick (#Striker2102) to replicate a VM or LXC to a second node.

# [pve-backup and pve-restore scripts ](/pve-backup/README.md)

Two Bash scripts for backing up and selectively restoring the configuration of
a Proxmox VE host. No black magic — just the tedious legwork that otherwise
hands you grey hairs after a reinstall: networking, storage definitions,
VM/CT configs, and all that PCI-passthrough fiddling.
