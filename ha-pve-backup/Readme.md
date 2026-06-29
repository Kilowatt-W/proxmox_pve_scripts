# set_pve_backup.sh

A Proxmox VE **vzdump hook script** that backs up the host's configuration
alongside the regular VM/CT backups. On every backup job it:

1. flags **Home Assistant** that a PVE backup is running (optional),
2. archives the **PVE configuration** (`/etc/pve`) and the **`/opt`** directory
   into timestamped ZIP files,
3. copies both archives to **two backup destinations** (mount points),
4. enforces **retention** per destination (separately for PVE config and `/opt`),
5. writes a **per-run log**, and
6. sends an optional **Telegram** notification with the result.

It is designed to be safe inside a backup hook: a failure of the host-config
backup will **not** abort your actual VM/CT backups (see [Exit behaviour](#exit-behaviour)).

---

## Contents

- [Requirements](#requirements)
- [How it hooks into vzdump](#how-it-hooks-into-vzdump)
- [Installation](#installation)
- [Configuration reference](#configuration-reference)
- [Security: token handling](#security-token-handling)
- [Logging](#logging)
- [Output & archive naming](#output--archive-naming)
- [Home Assistant setup](#home-assistant-setup)
- [Telegram setup](#telegram-setup)
- [Manual testing](#manual-testing)
- [Restoring from an archive](#restoring-from-an-archive)
- [Exit behaviour](#exit-behaviour)
- [Troubleshooting](#troubleshooting)

---

## Requirements

- Proxmox VE 7.x / 8.x (uses standard vzdump hook phases)
- `bash`, `zip`, `curl`, `mountpoint`, `mktemp` (all present on a default PVE host)
- Two writable backup targets, each on its **own mount point** (e.g. an NFS share
  and a ZFS dataset)
- Optional: a Home Assistant instance with a long-lived access token
- Optional: a Telegram bot and a target chat/group/channel

---

## How it hooks into vzdump

vzdump calls a configured hook script once per lifecycle phase and prefixes the
script's stdout with `INFO:` in the task log. This script reacts to:

| Phase        | Action                                                                 |
|--------------|------------------------------------------------------------------------|
| `job-start`  | HA flag → **on**; build archives; copy to destinations; prune; Telegram summary |
| `job-end`    | HA flag → **off**                                                      |
| `job-abort`  | HA flag → **off**; Telegram alert (always)                             |
| everything else (`backup-start`, `backup-end`, `pre-stop`, …) | no-op |

The host-config backup itself runs entirely during **`job-start`**, before the
first VM/CT is processed.

---

## Installation

```bash
cp set_pve_backup.sh /opt/set_pve_backup.sh
chmod 700 /opt/set_pve_backup.sh        # may hold tokens inline
```

Register it as the global vzdump hook in `/etc/vzdump.conf`:

```
script: /opt/set_pve_backup.sh
```

Verify it is picked up:

```bash
grep '^script:' /etc/vzdump.conf
```

> The hook is **global** — it runs for every vzdump job on this node, regardless
> of whether the job is GUI-defined or run from the CLI. Repeat the install on
> each PVE node you want covered.

---

## Configuration reference

All settings live in the **Configuration** block at the top of the script.

### What to back up

| Variable        | Default       | Meaning                                                        |
|-----------------|---------------|----------------------------------------------------------------|
| `PVE_CONF_DIR`  | `/etc/pve`    | Proxmox cluster configuration directory                        |
| `OPT_DIR`       | `/opt`        | Second directory to archive                                    |
| `OPT_EXCLUDES`  | empty         | `zip` glob patterns to exclude from the `/opt` archive, **without** the leading slash (e.g. `opt/ovftool/*`) |

### Destinations

Each destination is a pair: a **mount point** that must be mounted, and the
**path** to write into. If the mount point is not mounted, the script logs an
error and skips that destination — it never writes to the underlying root
filesystem.

| Variable       | Example                                          |
|----------------|--------------------------------------------------|
| `DEST1_MOUNT`  | `/mnt/pve/data_nfs_dc`                            |
| `DEST1_PATH`   | `${DEST1_MOUNT}/pve-host-backup/${HOSTNAME}`      |
| `DEST2_MOUNT`  | `/zfs_pool`                                       |
| `DEST2_PATH`   | `${DEST2_MOUNT}/pve-host-backup/${HOSTNAME}`      |

### Retention

| Variable         | Default | Meaning                                                  |
|------------------|---------|----------------------------------------------------------|
| `KEEP_LAST`      | `14`    | Default number of archives kept **per type, per destination** |
| `KEEP_LAST_PVE`  | empty   | Override for PVE-config archives (empty → use `KEEP_LAST`) |
| `KEEP_LAST_OPT`  | empty   | Override for `/opt` archives (empty → use `KEEP_LAST`)   |

`0` (or empty/non-numeric) means **keep all**. Because `/opt` archives are
usually much larger than `/etc/pve` archives, keeping many config snapshots but
few `/opt` snapshots is a common setup, e.g. `KEEP_LAST_PVE=30`, `KEEP_LAST_OPT=5`.

### Home Assistant (optional)

| Variable        | Default | Meaning                                              |
|-----------------|---------|------------------------------------------------------|
| `HA_ENABLE`     | `1`     | `0` disables the HA notification entirely            |
| `HA_URL`        | —       | REST endpoint of the `input_boolean` to toggle       |
| `HA_TOKEN`      | empty   | Long-lived access token (inline)                     |
| `HA_TOKEN_FILE` | empty   | Read token from this file when `HA_TOKEN` is empty   |
| `HA_INSECURE`   | `1`     | `1` adds `curl --insecure` (self-signed certificate) |
| `HA_TIMEOUT`    | `10`    | Request timeout in seconds                           |

### Telegram (optional)

| Variable             | Default | Meaning                                                   |
|----------------------|---------|-----------------------------------------------------------|
| `TG_ENABLE`          | `0`     | `1` enables Telegram notifications                        |
| `TG_BOT_TOKEN`       | empty   | Bot token `123456:ABC...` (inline)                        |
| `TG_BOT_TOKEN_FILE`  | empty   | Read token from this file when `TG_BOT_TOKEN` is empty    |
| `TG_CHAT_ID`         | empty   | Target id — groups use a **negative** number; public channels may use `@name` |
| `TG_ONLY_ON_ERROR`   | `0`     | `1` = only notify on errors (a `job-abort` always notifies) |
| `TG_TIMEOUT`         | `10`    | Request timeout in seconds                                 |

### Logging & behaviour

| Variable         | Default                  | Meaning                                          |
|------------------|--------------------------|--------------------------------------------------|
| `LOG_DIR`        | `/var/log/pve-host-backup` | Where per-run logs are written                 |
| `LOG_KEEP_LAST`  | `30`                     | Number of log files to keep (`0` = keep all)     |
| `STRICT`         | `0`                      | `1` = exit non-zero on error — **this aborts vzdump** |

---

## Security: token handling

An **inline** token (`HA_TOKEN` / `TG_BOT_TOKEN`) is convenient but dangerous
here: the script lives in `/opt`, and `/opt` is archived and copied to both
destinations on every run. An inline token therefore ends up in **cleartext** on
both backup targets.

**Recommended:** keep tokens in files **outside** every archived path
(neither under `/opt` nor under `/etc/pve`):

```bash
install -d -m 700 /etc/pve-host-backup
printf '%s' 'YOUR_HA_TOKEN'  > /etc/pve-host-backup/ha_token
printf '%s' 'YOUR_TG_TOKEN'  > /etc/pve-host-backup/tg_token
chmod 600 /etc/pve-host-backup/*
```

```bash
HA_TOKEN_FILE="/etc/pve-host-backup/ha_token"
TG_BOT_TOKEN_FILE="/etc/pve-host-backup/tg_token"
```

Notes:

- `/etc/pve-host-backup` is a **sibling** of `/etc/pve`, not inside it, so it is
  not captured by the PVE-config archive.
- Use `printf '%s'`, not `echo`, to avoid a trailing newline. The script strips
  all whitespace from token files anyway, but a clean file is one less surprise.
- Tokens are never written to the log; only HTTP status codes and the API's
  error description are logged.

---

## Logging

One log file per run:

```
/var/log/pve-host-backup/pve-host-backup_<hostname>_<YYYYmmdd-HHMMSS>.log
```

Each line is timestamped and also printed to stdout (so it appears in the vzdump
task log under `INFO:`). Old logs are pruned to `LOG_KEEP_LAST`. A run ends with
a one-line summary, e.g.:

```
PVE config: 132K | /opt: 511M | destinations: 2/2
```

---

## Output & archive naming

Archives are built in a temporary staging directory (`/var/tmp/…`, auto-removed)
and copied to each destination as:

```
<hostname>_pve-conf_<YYYYmmdd-HHMMSS>.zip
<hostname>_opt_<YYYYmmdd-HHMMSS>.zip
```

`zip` stores paths without the leading slash (`etc/pve/...`, `opt/...`).
Building in staging (not in `/opt`) prevents previous archives from being pulled
into the next `/opt` archive.

---

## Home Assistant setup

1. Create a helper: **Settings → Devices & Services → Helpers → Toggle**, named
   so its entity id is `input_boolean.pve_backup_running` (adjust `HA_URL` if you
   pick another id).
2. Create a long-lived access token: **Profile → Security → Long-lived access
   tokens**.
3. Put the token in `HA_TOKEN_FILE` and set `HA_URL` to point at your instance.

The script sets the boolean **on** at `job-start` and **off** at `job-end` /
`job-abort`, which you can use in automations (e.g. suppress restarts while a
backup runs).

> Setting state via `/api/states/...` overrides the state object directly; it is
> simple and sufficient for a "backup running" flag. If you prefer the canonical
> approach, call the `input_boolean.turn_on` / `turn_off` services instead.

---

## Telegram setup

1. Create a bot with **@BotFather** → `/newbot`; note the token `123456:ABC...`.
2. Add the bot to the target chat/group (or make it admin of a channel).
3. Find the chat id: post a message in the chat, then:

   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" \
     | grep -o '"chat":{"id":[-0-9]*'
   ```

   Groups/supergroups use a **negative** id (e.g. `-1001460143142`).
   If the bot has privacy mode on, send `/start@yourbot` so the update appears.
4. Verify the token independently:

   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getMe"; echo
   ```

   `{"ok":true,...}` → token good. `404 Not Found` → token wrong/malformed.
5. Set `TG_ENABLE=1`, `TG_BOT_TOKEN_FILE`, and `TG_CHAT_ID`.

---

## Manual testing

Run the backup logic without launching a real vzdump job:

```bash
/opt/set_pve_backup.sh run
tail -n 40 /var/log/pve-host-backup/pve-host-backup_$(uname -n)_*.log
```

`run` and `--test` are aliases for the `job-start` path.

---

## Restoring from an archive

The archives are plain ZIPs; restore selectively rather than overwriting blindly.

```bash
mkdir -p /tmp/restore && cd /tmp/restore
unzip /path/to/<hostname>_pve-conf_<ts>.zip      # extracts etc/pve/...
```

> `/etc/pve` is a FUSE filesystem (pmxcfs) backed by the cluster database. Do
> **not** bulk-overwrite it. Copy back individual files (e.g. a single
> `qemu-server/<vmid>.conf`, `storage.cfg`, firewall rules) as needed, and be
> aware that some files are node-specific. For `/opt`, a normal `unzip` to the
> target location is fine.

---

## Exit behaviour

A vzdump hook that exits non-zero **aborts the entire backup job**. Since the
host-config backup is secondary to the VM/CT backups, the script defaults to
collecting errors, logging them, and exiting `0` regardless — your VM backups
always proceed.

Set `STRICT=1` only if you explicitly want a failed host-config backup to fail
the whole vzdump job.

---

## Troubleshooting

| Symptom (in the log)                                             | Cause / fix                                                                 |
|------------------------------------------------------------------|------------------------------------------------------------------------------|
| `Destination not mounted: <mount> — skipping`                    | The target mount point isn't mounted. Mount it (or fix the NFS/ZFS export) and retry. The script intentionally refuses to write to the underlying root fs. |
| HA: `HTTP 401`                                                   | Wrong/expired HA token. Regenerate the long-lived token.                    |
| HA: `HTTP 404`                                                   | The `input_boolean` entity doesn't exist or `HA_URL` is wrong.              |
| Telegram: `HTTP 404 — Not Found`                                 | **Bot token** is wrong/malformed (not a chat issue). Verify with `/getMe`.  |
| Telegram: `HTTP 401`                                             | Token is well-formed but invalid/revoked. Issue a new one via @BotFather.   |
| Telegram: `HTTP 400 — Bad Request: chat not found`              | Wrong `TG_CHAT_ID`. Groups use a negative numeric id.                       |
| `Telegram not configured ... — skipping`                         | `TG_BOT_TOKEN`/`TG_BOT_TOKEN_FILE` empty or `TG_CHAT_ID` empty.             |
| `Could not create staging directory`                             | `/var/tmp` not writable or full.                                            |
| Archive missing on a target but no copy error                    | Check the per-run log; the archive may have failed to build (`zip rc=...`). |

---

*Last updated for the version of `set_pve_backup.sh` with dual destinations,
per-type retention, optional Home Assistant and Telegram notifications, and
file-based token handling.*
