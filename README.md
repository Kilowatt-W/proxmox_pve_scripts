# proxmox_pve_scripts
Scripts to tune and replicate Proxmox PVE hosts

# [zfs_replicate.sh](/zfs_replicate/)

Replication of ZFS datasets belonging to a Proxmox VE guest (VM or LXC
container) from a local Proxmox host to a remote Proxmox host.
Script inspired by my colleague Patrick (#Striker2102) to replicate a VM or LXC to a second node.

# [pve-backup and pve-restore scripts ](/pve-backup/)

Two Bash scripts for backing up and selectively restoring the configuration of
a Proxmox VE host. No black magic — just the tedious legwork that otherwise
hands you grey hairs after a reinstall: networking, storage definitions,
VM/CT configs, and all that PCI-passthrough fiddling.

# [pve-backup Script to copy pve-backup Server config and notify Home Assistant](/ha-pve-backup/)

A Proxmox VE vzdump hook script that backs up the host's configuration
alongside the regular VM/CT backups. On every backup job it:
*  flags Home Assistant that a PVE backup is running (optional),
*  archives the PVE configuration (/etc/pve) and the /opt directory into timestamped ZIP files,
*  copies both archives to two backup destinations (mount points),
*  enforces retention per destination (separately for PVE config and /opt),
*  writes a per-run log, and sends an optional Telegram notification with the result.
