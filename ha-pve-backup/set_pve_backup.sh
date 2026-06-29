#!/usr/bin/env bash
#
# set_pve_backup.sh — Proxmox VE vzdump hook script
# ---------------------------------------------------------------------------
# Purpose:
#   Runs as a vzdump hook. On 'job-start' it flags Home Assistant that a PVE
#   backup is running, archives the PVE configuration (/etc/pve) and the /opt
#   directory, and copies both archives to TWO backup destinations (mount
#   points). On 'job-end' / 'job-abort' it clears the HA flag.
#
# Install:
#   1) cp set_pve_backup.sh /opt/set_pve_backup.sh
#   2) chmod 700 /opt/set_pve_backup.sh        # it can hold an HA token
#   3) add to /etc/vzdump.conf:
#          script: /opt/set_pve_backup.sh
#
# Manual test (without running a real backup):
#   /opt/set_pve_backup.sh run
#
# DESIGN NOTE — why this script tries hard to exit 0:
#   A vzdump hook that exits non-zero ABORTS the whole backup job. Backing up
#   the host config is a "nice to have" next to the actual VM/CT backups, so by
#   default this script never lets a config-copy failure kill the VM backups:
#   it logs every error and still exits 0. Set STRICT=1 to make it fail loudly.
# ---------------------------------------------------------------------------

set -uo pipefail

# ===========================================================================
# Configuration  (edit these)
# ===========================================================================
HOSTNAME="$(uname -n)"

# --- What to back up -------------------------------------------------------
PVE_CONF_DIR="/etc/pve"            # Proxmox cluster configuration
OPT_DIR="/opt"                     # /opt (scripts, ovftool, community-scripts, ...)

# Optional excludes for the /opt archive. zip glob patterns, WITHOUT the
# leading slash (zip stores paths as 'opt/...'). Leave empty to back up all.
OPT_EXCLUDES=(
  # "opt/ovftool/*"
  # "opt/*.zip"
)

# --- Backup destination 1 --------------------------------------------------
# DEST*_MOUNT must be a real mount point. The script refuses to write if it is
# NOT mounted, so a dead NFS/ZFS target can never silently fill the root fs.
DEST1_MOUNT="/mnt/pve/data_nfs_dc"
DEST1_PATH="${DEST1_MOUNT}/pve-host-backup/${HOSTNAME}"

# --- Backup destination 2 --------------------------------------------------
DEST2_MOUNT="/zfs_pool"
DEST2_PATH="${DEST2_MOUNT}/pve-host-backup/${HOSTNAME}"

# --- Retention -------------------------------------------------------------
KEEP_LAST=14                       # default retention per archive type per dest (0 = keep all)
KEEP_LAST_PVE=""                   # how many PVE-config backups to keep (empty = use KEEP_LAST)
KEEP_LAST_OPT=""                   # how many /opt backups to keep        (empty = use KEEP_LAST)

# --- Home Assistant notification (optional) --------------------------------
HA_ENABLE=1                        # 0 = skip HA notification entirely
HA_URL="https://ha.kw-world.net:8123/api/states/input_boolean.pve_backup_running"
HA_TOKEN=""                        # HA long-lived access token (inline). 401 => wrong/expired.
                                   #   SECURITY: an inline token is archived into the /opt zip in
                                   #   cleartext and copied to BOTH destinations. Prefer the token
                                   #   file below, kept OUTSIDE /opt and /etc/pve.
HA_TOKEN_FILE=""                   # optional: read token from this file when HA_TOKEN is empty,
                                   #   e.g. /etc/pve-host-backup/ha_token  (chmod 600; NOT under
                                   #   /opt or /etc/pve, or you leak it into the backup again)
HA_INSECURE=1                      # 1 = curl --insecure (self-signed cert)
HA_TIMEOUT=10                      # seconds

# --- Telegram notification (optional) --------------------------------------
TG_ENABLE=0                        # 1 = send a Telegram message with the backup result
TG_BOT_TOKEN=""                    # bot token "123456:ABC..." (inline). Same leak caveat as HA_TOKEN.
TG_BOT_TOKEN_FILE=""               # optional: read token from this file when TG_BOT_TOKEN is empty,
                                   #   e.g. /etc/pve-host-backup/tg_token  (chmod 600; OUTSIDE /opt & /etc/pve)
TG_CHAT_ID=""                      # target id: group/chat = NEGATIVE number (e.g. -100xxxxxxxxxx);
                                   #   public channel may also use "@channelname". Get it via /getUpdates.
                                   #   (For a channel the bot must be an admin; for a group, membership is enough.)
TG_ONLY_ON_ERROR=0                 # 1 = only ping when something went wrong (job-abort always pings)
TG_TIMEOUT=10                      # seconds

# --- Logging ---------------------------------------------------------------
LOG_DIR="/var/log/pve-host-backup"
LOG_KEEP_LAST=30                   # keep newest N log files (0 = keep all)

# --- Behaviour -------------------------------------------------------------
STRICT=0                           # 1 = exit non-zero on error (this ABORTS vzdump!)

# ===========================================================================
# Internals  (no need to edit below)
# ===========================================================================
PHASE="${1:-}"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/pve-host-backup_${HOSTNAME}_${TS}.log"
ERRORS=0
STAGING=""
RUN_SUMMARY=""                     # one-line result, filled by run_backup, used by Telegram
DEST_OK_COUNT=0                    # how many destinations got a full copy

# Destination list: each entry is "MOUNT|PATH"
DESTS=(
  "${DEST1_MOUNT}|${DEST1_PATH}"
  "${DEST2_MOUNT}|${DEST2_PATH}"
)

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  # Timestamped; goes to the log file AND stdout (vzdump prefixes stdout INFO:)
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" | tee -a "$LOG_FILE"
}

err() {
  log "ERROR: $*"
  ERRORS=$((ERRORS + 1))
}

cleanup() {
  [ -n "${STAGING:-}" ] && rm -rf "$STAGING" 2>/dev/null || true
}
trap cleanup EXIT

finish() {
  if [ "$ERRORS" -gt 0 ]; then
    log "Finished phase '${PHASE}' WITH ${ERRORS} error(s). Log: ${LOG_FILE}"
    [ "$STRICT" -eq 1 ] && exit 1
  else
    log "Finished phase '${PHASE}' OK. Log: ${LOG_FILE}"
  fi
  exit 0
}

notify_ha() {
  # $1 = state (on|off). Never fatal, never logs the token.
  local state="$1" code
  local curlopts=(--silent --show-error --location --max-time "$HA_TIMEOUT")

  [ "$HA_ENABLE" -eq 1 ] || { log "HA notification disabled — skipping (state=${state})"; return 0; }

  # Resolve token: inline HA_TOKEN wins; otherwise read it from HA_TOKEN_FILE.
  if [ -z "$HA_TOKEN" ] && [ -n "$HA_TOKEN_FILE" ]; then
    if [ -r "$HA_TOKEN_FILE" ]; then
      HA_TOKEN="$(tr -d '[:space:]' < "$HA_TOKEN_FILE")"
    else
      err "HA_TOKEN_FILE not readable: ${HA_TOKEN_FILE}"
    fi
  fi
  if [ -z "$HA_TOKEN" ]; then
    err "No HA token available (HA_TOKEN empty, HA_TOKEN_FILE unset/unreadable) — skipping HA notify (state=${state})."
    return 1
  fi
  [ "$HA_INSECURE" -eq 1 ] && curlopts+=(--insecure)

  code="$(curl "${curlopts[@]}" \
            -o /dev/null -w '%{http_code}' \
            -X POST "$HA_URL" \
            -H "Authorization: Bearer ${HA_TOKEN}" \
            -H 'Content-Type: application/json' \
            -d "{\"state\": \"${state}\"}" 2>>"$LOG_FILE")" || true

  if [[ "$code" =~ ^2 ]]; then
    log "HA notified: pve_backup_running=${state} (HTTP ${code})"
  else
    err "HA notification failed: state=${state}, HTTP ${code:-000} (401=bad/expired token, 404=entity missing)"
  fi
}

notify_telegram() {
  # $1 = force (1 = send even if TG_ONLY_ON_ERROR and no errors).
  # Never fatal, never logs the token.
  local force="${1:-0}" code status msg

  [ "$TG_ENABLE" -eq 1 ] || return 0
  if [ "$force" -ne 1 ] && [ "${TG_ONLY_ON_ERROR:-0}" -eq 1 ] && [ "$ERRORS" -eq 0 ]; then
    log "Telegram: success suppressed by TG_ONLY_ON_ERROR"
    return 0
  fi

  # Resolve token: inline TG_BOT_TOKEN wins; otherwise read TG_BOT_TOKEN_FILE.
  if [ -z "$TG_BOT_TOKEN" ] && [ -n "$TG_BOT_TOKEN_FILE" ]; then
    if [ -r "$TG_BOT_TOKEN_FILE" ]; then
      TG_BOT_TOKEN="$(tr -d '[:space:]' < "$TG_BOT_TOKEN_FILE")"
    else
      err "TG_BOT_TOKEN_FILE not readable: ${TG_BOT_TOKEN_FILE}"
    fi
  fi
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    err "Telegram not configured (bot token or chat id missing) — skipping."
    return 1
  fi

  if [ "$ERRORS" -gt 0 ]; then status="WITH ${ERRORS} error(s)"; else status="OK"; fi

  msg="PVE host-config backup — ${HOSTNAME}"$'\n'
  msg+="Phase:  ${PHASE}"$'\n'
  msg+="Status: ${status}"$'\n'
  [ -n "${RUN_SUMMARY:-}" ] && msg+="${RUN_SUMMARY}"$'\n'
  msg+="Time:   $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
  msg+="Log:    ${LOG_FILE}"

  local resp body desc
  resp="$(curl --silent --show-error --max-time "$TG_TIMEOUT" \
            -w $'\n%{http_code}' \
            -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            --data-urlencode "text=${msg}" 2>>"$LOG_FILE")" || true
  code="${resp##*$'\n'}"                                   # last line = http_code
  body="${resp%$'\n'*}"                                    # everything before = JSON body
  desc="$(printf '%s' "$body" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"

  if [[ "$code" =~ ^2 ]]; then
    log "Telegram notified (HTTP ${code})"
  else
    err "Telegram notification failed: HTTP ${code:-000}${desc:+ — ${desc}}"
    err "  hint: 404 = wrong/malformed bot token (verify with /getMe) | 401 = invalid token | 400 'chat not found' = wrong chat_id (groups use a NEGATIVE numeric id)"
  fi
}

make_archive() {
  # $1 = label, $2 = source dir, $3 = output zip, $4.. = exclude globs
  local label="$1" src="$2" out="$3"; shift 3
  local excludes=("$@") rc

  if [ ! -e "$src" ]; then
    err "Source for ${label} does not exist: ${src} — skipping"
    return 1
  fi

  log "Archiving ${label}: ${src} -> $(basename "$out")"
  if [ "${#excludes[@]}" -gt 0 ]; then
    zip -r -q "$out" "$src" -x "${excludes[@]}" >>"$LOG_FILE" 2>&1
  else
    zip -r -q "$out" "$src" >>"$LOG_FILE" 2>&1
  fi
  rc=$?

  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    err "Failed to create archive for ${label} (zip rc=${rc}): ${out}"
    return 1
  fi
  log "  ${label} archive OK: $(du -h "$out" | cut -f1) ($(basename "$out"))"
  return 0
}

prune_dest() {
  # Keep newest N of each archive type in $1, where N is per-type configurable.
  local dir="$1" type keep old f
  for type in pve-conf opt; do
    case "$type" in
      pve-conf) keep="${KEEP_LAST_PVE:-$KEEP_LAST}" ;;
      opt)      keep="${KEEP_LAST_OPT:-$KEEP_LAST}" ;;
    esac
    [ "$keep" -gt 0 ] 2>/dev/null || continue          # 0 / empty / non-numeric => keep all
    mapfile -t old < <(ls -1t "${dir}/${HOSTNAME}_${type}_"*.zip 2>/dev/null | tail -n +"$((keep + 1))")
    for f in "${old[@]}"; do
      rm -f "$f" 2>>"$LOG_FILE" && log "Pruned old ${type} archive: $(basename "$f")"
    done
  done
}

copy_to_dest() {
  # $1 = "MOUNT|PATH"
  local entry="$1" mount path f rc=0
  mount="${entry%%|*}"
  path="${entry#*|}"

  if ! mountpoint -q "$mount"; then
    err "Destination not mounted: ${mount} — skipping (refusing to write to underlying root fs)"
    return 1
  fi
  if ! mkdir -p "$path" 2>>"$LOG_FILE"; then
    err "Cannot create destination directory: ${path}"
    return 1
  fi

  for f in "$STAGING"/*.zip; do
    [ -e "$f" ] || continue
    if cp -f "$f" "$path/" 2>>"$LOG_FILE"; then
      log "Copied $(basename "$f") -> ${path}/"
    else
      err "Copy failed: $(basename "$f") -> ${path}/"
      rc=1
    fi
  done

  prune_dest "$path"
  [ "$rc" -eq 0 ] && DEST_OK_COUNT=$((DEST_OK_COUNT + 1))
  return "$rc"
}

prune_logs() {
  [ "$LOG_KEEP_LAST" -gt 0 ] || return 0
  local old f
  mapfile -t old < <(ls -1t "${LOG_DIR}/pve-host-backup_${HOSTNAME}_"*.log 2>/dev/null | tail -n +"$((LOG_KEEP_LAST + 1))")
  for f in "${old[@]}"; do
    rm -f "$f" 2>/dev/null
  done
}

run_backup() {
  log "=== PVE host-config backup START (host=${HOSTNAME}, ts=${TS}) ==="
  log "Destinations: ${DEST1_PATH} | ${DEST2_PATH}"
  log "Retention: pve-conf=${KEEP_LAST_PVE:-$KEEP_LAST}, opt=${KEEP_LAST_OPT:-$KEEP_LAST} (per destination)"

  STAGING="$(mktemp -d /var/tmp/pve-host-backup.XXXXXX 2>>"$LOG_FILE")"
  if [ -z "$STAGING" ] || [ ! -d "$STAGING" ]; then
    err "Could not create staging directory — aborting config backup."
    return 1
  fi

  local pve_zip="${STAGING}/${HOSTNAME}_pve-conf_${TS}.zip"
  local opt_zip="${STAGING}/${HOSTNAME}_opt_${TS}.zip"

  make_archive "PVE config" "$PVE_CONF_DIR" "$pve_zip"
  make_archive "/opt"       "$OPT_DIR"      "$opt_zip" "${OPT_EXCLUDES[@]}"

  local d
  for d in "${DESTS[@]}"; do
    copy_to_dest "$d"
  done

  # Build a one-line summary for the logs and the Telegram message.
  local pve_sz="FAILED" opt_sz="FAILED"
  [ -s "$pve_zip" ] && pve_sz="$(du -h "$pve_zip" | cut -f1)"
  [ -s "$opt_zip" ] && opt_sz="$(du -h "$opt_zip" | cut -f1)"
  RUN_SUMMARY="PVE config: ${pve_sz} | /opt: ${opt_sz} | destinations: ${DEST_OK_COUNT}/${#DESTS[@]}"
  log "$RUN_SUMMARY"

  prune_logs
}

# ===========================================================================
# Phase dispatch
# ===========================================================================
case "$PHASE" in
  job-start|run|--test)
    notify_ha "on"
    run_backup
    notify_telegram          # success/error summary of the config backup
    finish
    ;;

  job-end)
    log "=== PVE backup job 'job-end' (host=${HOSTNAME}) ==="
    notify_ha "off"
    finish
    ;;

  job-abort)
    log "=== PVE backup job 'job-abort' (host=${HOSTNAME}) ==="
    notify_ha "off"
    err "vzdump reported job-abort"
    notify_telegram 1        # always ping on abort, even with TG_ONLY_ON_ERROR
    finish
    ;;

  *)
    # backup-start / backup-end / pre-stop / pre-restart / ... — nothing to do.
    exit 0
    ;;
esac
