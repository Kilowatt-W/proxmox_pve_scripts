# zfs_replicate.sh

Replication of ZFS datasets belonging to a Proxmox VE guest (VM or LXC
container) from a local Proxmox host to a remote Proxmox host.

The script manages a chain of `replicate-*` snapshots, automatically alternates
between incremental and full transfers, prunes old snapshots according to a
retention policy, and copies the guest configuration to the target host so the
replica can be started there if needed.

**Current version:** `260517_2.5`

---

## Quick start

```bash
# Show help, all options and the current configuration
./zfs_replicate.sh

# Auto mode: incremental until RETENTION is reached, then a full run
./zfs_replicate.sh 100

# Force a full replication (typical weekly cron job)
./zfs_replicate.sh 100 full

# Force an incremental replication (typical hourly cron job)
./zfs_replicate.sh 100 inc

# One-shot mirror of a STOPPED guest directly to the remote host
./zfs_replicate.sh 100 mirror
```

---

## Requirements

* Proxmox VE on both the local and the remote host.
* ZFS-backed storage for the guest disks on both sides.
* Key-based SSH access as `root` from the local to the remote host.
* `flock` (part of `util-linux`, present by default).
* `pv` is optional; if installed it is used to display transfer progress.

---

## Configuration

All settings live in clearly marked variables at the top of the script. No
function bodies need to be touched.

| Variable      | Default          | Meaning |
|---------------|------------------|---------|
| `REMOTE`      | `10.188.20.111`  | IP or hostname of the target Proxmox host. |
| `REMOTE_PORT` | `22`             | SSH port of the target host. |
| `RETENTION`   | `5`              | Number of incremental snapshots kept before a new full run is forced; also the size limit of the local snapshot chain. |
| `VERSION`     | `260517_2.5`     | Script version string. |
| `LOCKDIR`     | `/var/lock`      | Directory for the per-VMID lock file. |
| `LOCAL_POOL`  | `rpool`          | ZFS pool the source datasets live in on this host. |
| `REMOTE_POOL` | `rpool`          | ZFS pool the datasets are received into on `REMOTE`. |

If `LOCAL_POOL` and `REMOTE_POOL` are identical, every dataset is replicated to
the same path it has locally. If they differ, the leading pool component of
each dataset path is rewritten before `zfs receive`, e.g. with
`LOCAL_POOL="rpool"` and `REMOTE_POOL="tank"`:

```
rpool/data/vm-100-disk-0   ->   tank/data/vm-100-disk-0
```

> **Note:** `zfs receive` creates the target dataset, but the *parent* dataset
> must already exist on the remote host. When replicating into `tank/data/...`,
> make sure `tank/data` is present on the target before the first run.

---

## Modes

| Mode     | Description |
|----------|-------------|
| *(none)* | **Auto.** Incremental replication until `RETENTION` incrementals exist after the last full run, then a full run. |
| `full`   | Forces a full replication. Deletes all remote `replicate-*` snapshots for the guest and pushes the guest configuration to the remote host. Suitable for a weekly cron job. |
| `inc`    | Forces an incremental replication. Falls back to a full run if no usable base snapshot is found. Suitable for an hourly cron job. |
| `del`    | Deletes all local QM snapshots with the `replicate-` prefix for the guest. Nothing is transferred and the remote host is not contacted. |
| `mirror` | One-shot full mirror of a **stopped** guest. See below. |

Manually created QM snapshots (without the `replicate-` prefix) are never
touched by any mode.

### `mirror` mode

`mirror` performs a single full copy of a guest's datasets to the remote host
without participating in the managed snapshot chain or retention bookkeeping.

* The guest **must be stopped.** A running guest is refused, because a
  crash-consistent copy of a live disk is not a consistent backup.
* For each disk a transient `@mirror-<timestamp>` snapshot is created, sent in
  full, and then destroyed again on **both** sides.
* Dataset properties are sent along (`zfs send -p`).
* The guest configuration is copied to the remote host.

This is the intended way to seed a guest onto a second host, or to move a
powered-off guest, without disturbing an existing replication schedule.

---

## Options

| Option | Description |
|--------|-------------|
| `-h`, `--help`      | Show the help, all options and the current configuration. |
| `-v`, `--version`   | Show the framed version banner. |
| `-c`, `--clear`     | Delete **all** `replicate-*` snapshots in the pool. |
| `-l`, `--log <file>`| Append all output to `<file>` instead of printing to the screen. |

Running the script **without any parameter** prints the same help as `--help`
and exits with code `0`.

---

## Snapshot naming

Snapshots of the managed chain follow a strict format:

```
replicate-YYYYMMDD-HHMMSS-full
replicate-YYYYMMDD-HHMMSS-inc
```

The transient snapshots used by `mirror` mode follow:

```
mirror-YYYYMMDD-HHMMSS
```

---

## Behaviour and safeguards

* **Locking.** A per-VMID lock (`flock` on `${LOCKDIR}/zfs_replicate.<VMID>.lock`)
  prevents an hourly incremental run from colliding with a weekly full run for
  the same guest. A second run for the same VMID exits immediately.
* **Pre-flight check.** Before any transfer the target host is verified in three
  steps: an informational ICMP ping, a TCP reachability test of the SSH port,
  and an actual key-based SSH login test. The run aborts early with a clear
  message instead of failing halfway through a transfer.
* **Encrypted datasets** are detected automatically and sent raw (`zfs send -w`).
* **SSH multiplexing.** A single master SSH connection is reused for every
  subsequent `ssh`/`scp` call within a run.
* **Exit codes.** Help on no/`-h`/`-v` exits `0`. Usage errors (unknown option,
  unknown mode, too many arguments) print to *stderr* and exit `1`.

---

## Examples

### Cron schedule

```cron
# Hourly incremental replication of VM 100
0 * * * *   /usr/local/sbin/zfs_replicate.sh 100 inc -l /var/log/zfs_replicate.log

# Weekly full replication of VM 100, Sundays at 03:00
0 3 * * 0   /usr/local/sbin/zfs_replicate.sh 100 full -l /var/log/zfs_replicate.log
```

> Options and the VMID may be given in any order; `-l` simply needs its file
> argument directly after it.

### Mirror a stopped guest to a host with a differently named pool

```bash
# Edit the top of the script:
#   REMOTE="10.0.0.50"
#   LOCAL_POOL="rpool"
#   REMOTE_POOL="tank"

qm stop 100
./zfs_replicate.sh 100 mirror
```

### Inspect the active configuration on an unfamiliar host

```bash
./zfs_replicate.sh -h
```

### Remove the managed snapshot chain for a guest

```bash
# Local QM snapshots only, no transfer
./zfs_replicate.sh 100 del

# Every replicate-* snapshot in the whole pool
./zfs_replicate.sh -c
```

---

## Version history

### 2.0 — baseline

Initial modular version: auto/full/inc/del modes, retention handling,
incremental-with-full-fallback logic, optional log file.

### 2.0 → 2.1

* **Fix:** `zfs send -V` does not exist in OpenZFS — replaced with plain
  `zfs send`.
* **Fix:** `get_config_file()` leaked log lines into `stdout`, which corrupted
  `CONFIG_FILE` for LXC containers. All diagnostics now go to `stderr`.
* **Fix:** Proxmox storage IDs were turned into dataset paths naively
  (`storage:vol` → `storage/vol`). New `resolve_dataset()` maps the storage ID
  to the real pool path via `/etc/pve/storage.cfg`.
* **New:** `mirror` mode for one-shot offline guest mirroring.
* **New:** `flock`-based locking against overlapping cron runs.
* **New:** SSH connection multiplexing (`ControlMaster`).
* **New:** Encrypted datasets auto-detected and sent raw (`-w`).
* **Fix:** Empty snapshot lists no longer trigger `qm delsnapshot ""`.
* **Fix:** `clear_all_snapshots` uses a precise `replicate-` match instead of a
  loose `grep replica`.
* **Fix:** The temporary config file is removed via a `RETURN` trap even on
  failure.
* **Fix:** The remote configuration is pushed only on full/mirror runs, as the
  documentation always claimed.

### 2.1 → 2.2

* **New:** Pre-flight `check_remote()` — ICMP probe, TCP port reachability and a
  real SSH login test before any transfer.
* **New:** Configurable `REMOTE_PORT` for non-standard SSH ports.

### 2.2 → 2.3

* **New:** The local and remote ZFS pools are explicit variables
  (`LOCAL_POOL` / `REMOTE_POOL`). `remote_dataset()` rewrites the pool prefix on
  the receiving side, so source and target pools may have different names.
  Identical names reproduce the previous behaviour exactly.

### 2.3 → 2.4

* **New:** Running the script without parameters prints the full help (usage
  plus the current values of all configurable variables) and exits `0`.
* **New:** `print_help()` shows the version number as a header at the top and
  lists all configuration variables with their current values.
* **Fix:** Error messages and help-on-error output go to `stderr`.

### 2.4 → 2.5

* **New:** `-v`/`--version` prints the framed version banner instead of the bare
  version string.

---

## Files

| File                | Purpose |
|---------------------|---------|
| `zfs_replicate.sh`  | The replication script. |
| `README.md`         | This document. |

---

*Author: Kilowatt — script revisions v2.1–v2.5.*
