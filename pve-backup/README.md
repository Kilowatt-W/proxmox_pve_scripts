# PVE Host Config Tools

Two Bash scripts for backing up and selectively restoring the configuration of
a Proxmox VE host. No black magic — just the tedious legwork that otherwise
hands you grey hairs after a reinstall: networking, storage definitions,
VM/CT configs, and all that PCI-passthrough fiddling.

| Script | Purpose |
|--------|---------|
| `pve-config-backup.sh`  | Pack the configuration into a ZIP, optionally ship it off via SSH |
| `pve-config-restore.sh` | Fetch a ZIP, verify it, unpack it, and *selectively* restore paths |

## What this is — and what it is not

These scripts back up **configuration**, not a full bare-metal image. Guest
disks (VMs/CTs) are **not** included — that is the job of Proxmox Backup
Server, `vzdump`, or ZFS `send`/`recv`. If you want a bootable full-system
image, reach for Clonezilla. These tools rescue the settings, not the
terabytes.

> **`/etc/pve` is the pmxcfs cluster filesystem.** Files from it are never
> dumped blindly back onto a fresh host. In a cluster, `/etc/pve` resynchronises
> itself on rejoin anyway. The archive is meant as a *reference* for selective
> copying — not as `unzip` at full throttle.

## Requirements

- A Proxmox VE host (Debian-based), run as `root`
- `zip` for backup, `unzip` for restore
  - If missing: `apt-get install -y zip unzip`
- `sqlite3` (optional) for the SQL dump of the pmxcfs database
- SSH access to the target server if transfer is desired

## Installation

```bash
git clone <repo-url>
cd <repo>
chmod +x pve-config-backup.sh pve-config-restore.sh
```

---

## `pve-config-backup.sh`

Collects the relevant configuration files, packs them into a ZIP archive,
generates a SHA-256 checksum, and optionally transfers everything via SSH.

### Backup scope

Beyond the obvious `/etc/pve`, it also captures what tends to be forgotten when
you only copy `/etc/pve`: networking (`interfaces`), boot/IOMMU configuration
(`grub`, `kernel/cmdline`, `modules`, `modprobe.d`), LVM, SSH host keys, APT
repositories, cron, plus `passwd`/`shadow`/`group` and `subuid`/`subgid`
(important for unprivileged LXC). On top of that, the pmxcfs database
(`config.db` as a raw file **and** SQL dump) and a `BACKUP-MANIFEST.txt` with a
system inventory end up in the archive. Non-existent paths are skipped
silently.

### CLI parameters

| Option | Description | Default |
|--------|-------------|---------|
| `-o, --output FILE`    | Full path/name of the ZIP file | `<tmpdir>/<prefix>-<host>-<timestamp>.zip` |
| `-p, --prefix NAME`    | Filename prefix | `pve-config` |
| `-t, --tmpdir DIR`     | Working/output directory | `/tmp` |
| `-d, --dest TARGET`    | SSH target `user@host:/path/` | – (without it, local only) |
| `-P, --port PORT`      | SSH port | `22` |
| `-i, --identity FILE`  | SSH private key | – |
| `-r, --rsync`          | Use `rsync` instead of `scp` | off |
| `-e, --extra PATH`     | Additional path (repeatable) | – |
| `-k, --keep-local`     | Keep local ZIP after transfer | off |
| `-n, --no-transfer`    | Back up locally only | off |
| `-q, --quiet`          | Print warnings/errors only | off |
| `-h, --help`           | Show help | – |

### Examples

```bash
# 1) Local backup to /tmp only (default filename)
./pve-config-backup.sh -n

# 2) Create a backup and push it to the backup host via scp
./pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/

# 3) Custom key, port 2222, rsync, two extra paths
./pve-config-backup.sh -d root@10.0.0.9:/backups/ -P 2222 -i ~/.ssh/backup \
                       -r -e /etc/iscsi -e /root/scripts

# 4) Fixed filename and custom output directory
./pve-config-backup.sh -o /mnt/nas/pve01-config.zip -n

# 5) Keep the local copy after transfer
./pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/ -k
```

### Automation (cron)

Daily backup at 02:15. Pruning old archives is better handled on the target
host separately:

```cron
15 2 * * * root /opt/pve-tools/pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/ -q
```

---

## `pve-config-restore.sh`

Fetches an archive (local or via SSH), verifies the checksum, unpacks it, and —
**only when explicitly told to** — restores individual paths.

> **The default mode restores nothing.** It only unpacks and displays. That is
> deliberate: a restore script that overwrites `/etc` unprompted is not a tool,
> it is a trap. Only `--apply` actually puts something back — and even then the
> existing state is first saved to `<target>.bak-<timestamp>`.

### CLI parameters

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input FILE`     | Local ZIP archive | – |
| `-f, --from SSH-SRC`   | Fetch archive via SSH, `user@host:/path/x.zip` | – |
| `-P, --port PORT`      | SSH port for `--from` | `22` |
| `-I, --identity FILE`  | SSH private key for `--from` | – |
| `-t, --tmpdir DIR`     | Working directory | `/tmp` |
| `-l, --list`           | List archive contents and exit | off |
| `-D, --diff`           | Diff the archive against the running system | off |
| `-a, --apply PATH`     | Restore this path (repeatable) | – |
| `--allow-pve`          | Allow `--apply` for paths under `/etc/pve` | off |
| `--no-checksum`        | Skip the checksum check (not recommended) | off |
| `-y, --yes`            | Suppress confirmation prompts before restoring | off |
| `-q, --quiet`          | Print warnings/errors only | off |
| `-h, --help`           | Show help | – |

The source is **exactly one** of `--input` or `--from`.

### Examples

```bash
# 1) Just unpack and inspect the archive (changes nothing)
./pve-config-restore.sh -i /tmp/pve-config-pve01-20260518-021500.zip

# 2) List archive contents
./pve-config-restore.sh -i ./pve-config-pve01.zip -l

# 3) Fetch the archive from the backup host and diff it against the system
./pve-config-restore.sh -f backup@nas.local:/srv/pve-backups/pve-config-pve01.zip -D

# 4) Selectively restore networking and GRUB config (no prompts)
./pve-config-restore.sh -i ./pve-config-pve01.zip \
                        -a /etc/network/interfaces -a /etc/default/grub -y

# 5) Restore an /etc/pve path — only if you REALLY know what you are doing
./pve-config-restore.sh -i ./pve-config-pve01.zip \
                        -a /etc/pve/storage.cfg --allow-pve
```

### After a restore

Restart the affected services — the script reminds you, depending on which path
was restored:

```bash
systemctl restart networking      # after a networking restore
update-grub                       # after a GRUB restore
systemctl restart pve-cluster     # after an /etc/pve restore
```

---

## Typical workflow

```text
  Source host                         Backup server               Target host
 ┌────────────┐   pve-config-backup   ┌──────────────┐   restore   ┌──────────┐
 │ /etc/pve   │ ───────scp/rsync────► │  *.zip        │ ──────────► │  fresh   │
 │ /etc/...   │      + .sha256        │  *.zip.sha256 │   -i / -f   │  PVE     │
 └────────────┘                       └──────────────┘             └──────────┘
                                                              then selective -a
```

1. On the source host: `pve-config-backup.sh -d backup@host:/path/`
2. In an emergency, on the new host: `pve-config-restore.sh -f backup@host:/path/x.zip -D`
   (diff first, look, *then* selectively restore with `-a`)

## Restore strategy — short and painless

- **Diff before apply.** See what differs before you touch anything.
- **Check NIC names.** New hardware means new interface names. The
  `/etc/network/interfaces` from the archive may then not match 1:1.
- **`/etc/pve` is a special zone.** In a cluster it sorts itself out on rejoin;
  individual files only with `--allow-pve` and a clear head.
- **The best backup is a tested one.** Run the restore once on a throwaway host
  before the real emergency does it for you.

## License

Adjust as you like — e.g. MIT.
