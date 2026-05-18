#!/bin/bash
#
# zfs_replicate.sh  Version 2.5
#
# Script for replicating ZFS datasets of a VM/CT from a local Proxmox VE
# to a remote Proxmox VE.
#
# Modes:
#    zfs_replicate.sh <VMID> full     -> Force a FULL replication (e.g. weekly via cron;
#                                        deletes remote snapshots and updates the VM config).
#    zfs_replicate.sh <VMID> inc      -> Force an incremental replication (e.g. every few hours).
#    zfs_replicate.sh <VMID> del      -> Delete all local QM snapshots with the prefix
#                                        "replicate-" without transferring.
#    zfs_replicate.sh <VMID> mirror   -> One-shot full mirror of a STOPPED VM/CT directly to
#                                        the remote host. Uses a transient @mirror-* snapshot
#                                        that is removed on both sides afterwards. Does NOT
#                                        touch the "replicate-" snapshot chain or retention.
#    zfs_replicate.sh <VMID>          -> Auto mode (inc until RETENTION is reached, then full).
#
# Snapshot names of the managed chain strictly follow the format:
#    replicate-YYYYMMDD-HHMMSS-full
#    replicate-YYYYMMDD-HHMMSS-inc
#
# Manually created QM snapshots (without the "replicate-" prefix) remain untouched.
#
# Options:
#   -h, --help           Show this help message.
#   -v, --version        Show the version.
#   -c, --clear          Delete all replica snapshots in the pool.
#   -l, --log <file>     Append output to the specified log file instead of printing to screen.
#
# ----------------------------------------------------------------------------
# Changelog 2.0 -> 2.1
#   * FIX:  `zfs send -V` does not exist in OpenZFS -> replaced with plain `zfs send`
#           (optional `-v` only goes to stderr anyway).
#   * FIX:  get_config_file() polluted stdout via log_msg, so CONFIG_FILE captured
#           log lines for LXC containers -> all diagnostics now go to stderr.
#   * FIX:  Proxmox storage IDs were naively turned into dataset paths
#           (`storage:vol` -> `storage/vol`). New resolve_dataset() maps the
#           storage ID to the real pool path via /etc/pve/storage.cfg.
#   * NEW:  `mirror` mode for one-shot offline VM/CT mirroring.
#   * NEW:  flock-based locking so overlapping cron runs cannot collide.
#   * NEW:  SSH connection multiplexing (ControlMaster) to cut handshake overhead.
#   * NEW:  Encrypted datasets are auto-detected and sent raw (`-w`).
#   * FIX:  Empty snapshot lists no longer trigger `qm delsnapshot "" `.
#   * FIX:  clear_all_snapshots uses a precise `replicate-` match, not `grep replica`.
#   * FIX:  Temp config file is removed via a RETURN trap even on failure.
#   * FIX:  Remote config is only pushed for full/mirror runs, as documented.
#
# Changelog 2.1 -> 2.2
#   * NEW:  Pre-flight check_remote() verifies the target host before any
#           transfer: ICMP probe (informational), TCP reachability of the SSH
#           port, and an actual key-based SSH login test. The run aborts early
#           with a clear message instead of failing halfway through a send.
#   * NEW:  Configurable REMOTE_PORT for non-standard SSH ports.
#
# Changelog 2.2 -> 2.3
#   * NEW:  The local and remote ZFS pools are now explicit variables
#           (LOCAL_POOL / REMOTE_POOL) defined at the top of the script.
#           remote_dataset() rewrites the pool prefix on the receiving side,
#           so source and target pools may have different names. If both
#           variables are equal the behaviour is identical to before.
#
# Changelog 2.3 -> 2.4
#   * NEW:  Running the script without parameters now prints the full help
#           (usage + current values of all configurable variables) instead of
#           a bare usage line, and exits 0.
#   * NEW:  print_help() shows the version number as a header at the very top
#           and lists REMOTE, REMOTE_PORT, LOCAL_POOL, REMOTE_POOL, RETENTION
#           and LOCKDIR with their current values.
#   * FIX:  Error messages and the help-on-error output now go to stderr.
#
# Changelog 2.4 -> 2.5
#   * NEW:  -v/--version now prints the framed version banner (print_banner)
#           instead of the bare version string.
#
# Author: Kilowatt  (v2.1 - v2.5 revisions added)
# Date:   17.05.2026
#

# --- Basic Settings ---
REMOTE="10.188.20.111"
REMOTE_PORT=22
RETENTION=5
VERSION="260517_2.5"
LOCKDIR="/var/lock"

# --- ZFS Pools ---
# LOCAL_POOL  : the pool the source datasets live in on this host.
# REMOTE_POOL : the pool the datasets should be received into on ${REMOTE}.
# If both names are identical, replication targets the same dataset path as
# before. If they differ, the leading pool component of each dataset is
# rewritten from LOCAL_POOL to REMOTE_POOL before `zfs receive`.
LOCAL_POOL="rpool"
REMOTE_POOL="rpool"

# --- SSH connection multiplexing ---
# One master connection per run, reused by every subsequent ssh/scp call.
# Note: ssh uses '-p' for the port, scp uses '-P' -- hence the split below.
SSH_CTL_PATH="/tmp/.ssh-zfsrepl-%r@%h:%p"
SSH_COMMON="-o ControlMaster=auto -o ControlPath=${SSH_CTL_PATH} -o ControlPersist=60s -o BatchMode=yes"
SSH="ssh ${SSH_COMMON} -p ${REMOTE_PORT}"
SCP="scp ${SSH_COMMON} -P ${REMOTE_PORT}"

# --- Usage Message ---
USAGE=$(cat <<'EOF'
Usage: zfs_replicate.sh [OPTIONS] <VMID> [full|inc|del|mirror]

Script for replicating ZFS datasets from a local Proxmox VE to a remote host.

Modes:
  full     Force a FULL replication (e.g. weekly via cron; deletes remote snapshots
           and updates the VM config).
  inc      Force an incremental replication (e.g. every few hours).
  del      Delete all local QM snapshots with the prefix "replicate-" without transferring.
  mirror   One-shot full mirror of a STOPPED VM/CT directly to the remote host. Uses a
           transient snapshot that is cleaned up on both sides. Does not touch the
           "replicate-" snapshot chain or retention bookkeeping.
  (none)   Auto mode: incremental until RETENTION is reached, then full.

Options:
  -h, --help           Show this help message.
  -v, --version        Show the version.
  -c, --clear          Delete all replica snapshots in the pool.
  -l, --log <file>     Append output to the specified log file instead of printing to screen.

Note:
  Managed snapshot names follow the format:
    replicate-YYYYMMDD-HHMMSS-full
    replicate-YYYYMMDD-HHMMSS-inc

Manually created QM snapshots (without the "replicate-" prefix) remain untouched.
EOF
)

# --- Help / Banner Output ---
# print_banner : framed header line with the version number.
# print_help   : banner + usage message + current values of all variables.
#                Used for -h/--help and for parameter-less invocation.
print_banner() {
    echo "=============================================================="
    echo " zfs_replicate.sh   Version ${VERSION}"
    echo "=============================================================="
}

print_help() {
    print_banner
    echo
    echo "$USAGE"
    echo
    echo "Current configuration (edit these at the top of the script):"
    echo "  VERSION      = ${VERSION}"
    echo "  REMOTE       = ${REMOTE}"
    echo "  REMOTE_PORT  = ${REMOTE_PORT}"
    echo "  LOCAL_POOL   = ${LOCAL_POOL}"
    echo "  REMOTE_POOL  = ${REMOTE_POOL}"
    echo "  RETENTION    = ${RETENTION}"
    echo "  LOCKDIR      = ${LOCKDIR}"
    echo
}

# --- Logging Function ---
# Writes to the log file if -l was given, otherwise to stdout.
log_msg() {
    local msg="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -n "$LOGFILE" ]; then
        echo "$timestamp - $msg" >> "$LOGFILE"
    else
        echo "$timestamp - $msg"
    fi
}

# --- Diagnostic Logging (always stderr-safe) ---
# Use this inside functions whose stdout is captured via command substitution
# so log lines never leak into the captured value.
log_err() {
    log_msg "$1" >&2
}

# --- Count non-empty lines in a (possibly empty) multi-line string ---
count_lines() {
    local s="$1"
    if [ -z "${s//[[:space:]]/}" ]; then
        echo 0
    else
        printf '%s\n' "$s" | grep -c .
    fi
}

# --- Map a Proxmox disk reference (storage:volume) to its real ZFS dataset ---
# Reads the pool path of a zfspool storage from /etc/pve/storage.cfg.
# Falls back to the naive ':'->'/' replacement if the lookup fails.
resolve_dataset() {
    local ref="$1"                       # e.g. local-zfs:vm-100-disk-0
    local storage="${ref%%:*}"
    local volume="${ref#*:}"
    local pool

    pool=$(awk -v s="$storage" '
        $1=="zfspool:" && $2==s {found=1; next}
        /^[a-z]+:/                {found=0}
        found && $1=="pool"       {print $2; exit}
    ' /etc/pve/storage.cfg 2>/dev/null)

    if [ -n "$pool" ]; then
        echo "${pool}/${volume}"
    else
        log_err "Warning: could not resolve storage '${storage}' via storage.cfg; using naive path."
        echo "${ref/://}"
    fi
}

# --- Map a local dataset path to its equivalent on the remote pool ---
# Rewrites the leading LOCAL_POOL component to REMOTE_POOL. If both pools are
# named identically this is a no-op. Datasets not located under LOCAL_POOL are
# passed through unchanged with a warning, since their target is ambiguous.
remote_dataset() {
    local ds="$1"

    if [ "$LOCAL_POOL" = "$REMOTE_POOL" ]; then
        echo "$ds"
        return
    fi

    if [[ "$ds" == "${LOCAL_POOL}/"* ]]; then
        echo "${REMOTE_POOL}/${ds#"${LOCAL_POOL}"/}"
    elif [ "$ds" = "$LOCAL_POOL" ]; then
        echo "$REMOTE_POOL"
    else
        log_err "Warning: dataset '${ds}' is not under LOCAL_POOL '${LOCAL_POOL}'; targeting identical remote path."
        echo "$ds"
    fi
}

# --- Build zfs send flags for a dataset (raw send for encrypted datasets) ---
zfs_send_flags() {
    local ds="$1" enc
    enc=$(zfs get -H -o value encryption "$ds" 2>/dev/null || echo off)
    if [ "$enc" != "off" ] && [ "$enc" != "-" ] && [ -n "$enc" ]; then
        echo "-w"
    fi
}

# --- Send a ZFS stream, piping through pv if it is available ---
# Usage: send_stream <send-args...> -- <dataset> <receive-args...>
# Kept simple: callers build the full pipeline themselves; this is just the
# pv-aware helper used for the progress display.
have_pv() { command -v pv >/dev/null 2>&1; }

# --- Pre-flight: Verify the Remote Host is Reachable and SSH Login Works ---
# Three escalating checks. The run aborts early with a clear message instead
# of dying halfway through a `zfs send` because the target was never reachable.
check_remote() {
    log_msg "------------------------------------------"
    log_msg "Pre-flight check: verifying remote host ${REMOTE}:${REMOTE_PORT}..."

    # 1. ICMP probe -- informational only. Many hosts filter ping, so a missing
    #    reply is not treated as fatal; the TCP/SSH checks below are authoritative.
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 "$REMOTE" >/dev/null 2>&1; then
            log_msg "  ICMP : host responds to ping."
        else
            log_msg "  ICMP : no ping reply (may simply be filtered; continuing)."
        fi
    fi

    # 2. TCP reachability of the SSH port. Uses the bash /dev/tcp builtin so no
    #    nc/netcat dependency is required. A closed port means: host down, wrong
    #    address, firewall, or sshd not running.
    if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/${REMOTE}/${REMOTE_PORT}" 2>/dev/null; then
        log_msg "Error: TCP port ${REMOTE_PORT} on ${REMOTE} is not reachable."
        log_msg "       Host down, wrong address, firewall, or sshd not running?"
        exit 1
    fi
    log_msg "  TCP  : port ${REMOTE_PORT} is open."

    # 3. Actual SSH login test. BatchMode=yes (set in SSH_COMMON) makes a missing
    #    or unaccepted key fail immediately instead of hanging on a password
    #    prompt. This first call also warms up the ControlMaster connection.
    if ! $SSH -o ConnectTimeout=10 root@"${REMOTE}" 'true' 2>/dev/null; then
        log_msg "Error: SSH login to root@${REMOTE} failed."
        log_msg "       Check key-based auth, known_hosts, and that root login is permitted."
        exit 1
    fi
    log_msg "  SSH  : key-based login to root@${REMOTE} succeeded."
    log_msg "Pre-flight check passed."
}

# --- Clear All Replica Snapshots in Pool ---
clear_all_snapshots() {
    log_msg "Version: $VERSION"
    log_msg "Clearing all snapshots created by this script from the pool."
    local snap
    for snap in $(zfs list -H -t snapshot -o name | grep -- '@replicate-' || true); do
         log_msg "Destroying $snap"
         sudo zfs destroy "$snap"
    done
    exit 0
}

# --- Delete Local QM Snapshots (del mode) ---
delete_local_qm_snapshots() {
    log_msg "Mode 'del' selected: Deleting all local QM snapshots with prefix 'replicate-' for VMID $VMID."
    local qm_snap_list
    qm_snap_list=$(qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' || true)

    if [ "$(count_lines "$qm_snap_list")" -eq 0 ]; then
        log_msg "No replication QM snapshots found for VMID $VMID. Nothing to delete."
        exit 0
    fi

    log_msg "Found QM snapshots:"
    log_msg "$qm_snap_list"
    echo "$qm_snap_list" | awk '{print $1}' | while read -r snap; do
         [ -z "$snap" ] && continue
         log_msg "Deleting QM snapshot $snap..."
         qm delsnapshot "$VMID" "$snap"
    done
    log_msg "All local QM snapshots have been deleted."
    exit 0
}

# --- Determine VM/CT Configuration File ---
# IMPORTANT: all diagnostics go to stderr so the captured stdout is the path only.
get_config_file() {
    local vm_config_file="/etc/pve/qemu-server/${VMID}.conf"
    local lxc_config_file="/etc/pve/lxc/${VMID}.conf"

    if [ -f "$vm_config_file" ]; then
        echo "$vm_config_file"
    elif [ -f "$lxc_config_file" ]; then
        log_err "$VMID appears to be an LXC container; switching config path."
        echo "$lxc_config_file"
    else
        log_err "Error: Configuration file not found for VMID ${VMID}!"
        exit 1
    fi
}

# --- Is this VMID an LXC container? (based on the resolved config path) ---
is_lxc() {
    [[ "$CONFIG_FILE" == *"/lxc/"* ]]
}

# --- Get the run state of the guest ('running', 'stopped', ...) ---
guest_status() {
    if is_lxc; then
        pct status "$VMID" 2>/dev/null | awk '{print $2}'
    else
        qm status "$VMID" 2>/dev/null | awk '{print $2}'
    fi
}

# --- Collect disk datasets from the VM/CT config (resolved to real ZFS paths) ---
# Populates the global array DISK_DATASETS.
collect_disk_datasets() {
    DISK_DATASETS=()
    local line ref
    local -a disk_lines=()
    readarray -t disk_lines < <(sed '/^\[/q' "${CONFIG_FILE}" \
        | grep -E '^[[:space:]]*(scsi|sata|virtio|efidisk|tpmstate|rootfs|mp)[0-9]*:')

    log_msg "Found ${#disk_lines[@]} disk entries in ${CONFIG_FILE}."
    for line in "${disk_lines[@]}"; do
        ref=$(echo "$line" | sed -E 's/^[a-z]+[0-9]*:\s*([^,]+).*/\1/')
        if [ "$ref" = "none" ] || [ -z "$ref" ]; then
            log_msg "Skipping invalid disk entry: $line"
            continue
        fi
        DISK_DATASETS+=("$(resolve_dataset "$ref")")
    done
}

# --- Determine Replication Mode in Auto ---
determine_replication_mode() {
    local sorted_qm_snap_list last_full_ts inc_count inc_ts
    sorted_qm_snap_list=$(echo "$QM_SNAP_LIST" | sort -V)
    log_msg "Sorted local replication QM snapshots:"
    log_msg "$sorted_qm_snap_list"

    last_full_ts=$(echo "$sorted_qm_snap_list" | grep -E 'replicate-[0-9]{8}-[0-9]{6}-full' | cut -d'-' -f2-3 | sort -V | tail -n 1 || true)
    log_msg "Last FULL snapshot timestamp: $last_full_ts"

    if [ -n "$last_full_ts" ]; then
        inc_ts=$(echo "$sorted_qm_snap_list" | grep -E 'replicate-[0-9]{8}-[0-9]{6}-inc' | cut -d'-' -f2-3)
        if [ -z "$inc_ts" ]; then
            inc_count=0
        else
            inc_count=$(echo "$inc_ts" | awk -v last="$last_full_ts" 'BEGIN {count=0} { if ($0 > last) count++ } END { print count }')
        fi
    else
        inc_count=0
    fi
    log_msg "Number of incremental snapshots after the last FULL: $inc_count"

    if [ -n "$last_full_ts" ] && [ "$inc_count" -lt "$RETENTION" ]; then
        log_msg "Less than $RETENTION incremental snapshots found. New snapshot will be incremental (inc)."
        NEW_TYPE="inc"
    else
        log_msg "Either no FULL snapshot found or $RETENTION (or more) incremental snapshots exist. New snapshot will be FULL."
        NEW_TYPE="full"
    fi
}

# --- Create New QM Snapshot ---
create_new_qm_snapshot() {
    NEW_SNAP="replicate-$(date +'%Y%m%d-%H%M%S')-${NEW_TYPE}"
    log_msg "New snapshot name: $NEW_SNAP"

    if ! qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | awk '{print $1}' | grep -q "^${NEW_SNAP}$"; then
        log_msg "Creating new QM snapshot $NEW_SNAP..."
        qm snapshot "$VMID" "$NEW_SNAP" --description "Replication snapshot created on $(date)"
    else
        log_msg "Snapshot $NEW_SNAP already exists."
    fi

    # Update QM snapshot list
    QM_SNAP_LIST=$(qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' | sort -V || true)
    log_msg "Updated QM snapshot list:"
    log_msg "$QM_SNAP_LIST"
}

# --- Delete all remote 'replicate-' snapshots for a (remote) dataset ---
remote_purge_replica_snapshots() {
    local remote_ds="$1"
    $SSH root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${remote_ds}@replicate-'); do
        echo \"Deleting remote snapshot \$snap\";
        zfs destroy -R \"\$snap\";
    done" || log_msg "No remote snapshots to delete or an error occurred."
}

# --- Send a FULL snapshot of a dataset to the remote host ---
# Arg 1: local dataset path, Arg 2: remote dataset path (receive target).
send_full() {
    local disk_dataset="$1" remote_ds="$2" send_flags
    send_flags=$(zfs_send_flags "$disk_dataset")
    log_msg "Sending FULL ZFS snapshot ${disk_dataset}@${NEW_SNAP} -> ${remote_ds} (flags: ${send_flags:-none})..."
    if have_pv; then
        zfs send $send_flags "${disk_dataset}@${NEW_SNAP}" | pv | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"
    else
        zfs send $send_flags "${disk_dataset}@${NEW_SNAP}" | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"
    fi
}

# --- Replicate Disk for a Given Dataset ---
replicate_disk() {
    local disk_dataset="$1"
    local disk_label send_flags remote_ds
    disk_label=$(basename "$disk_dataset")
    remote_ds=$(remote_dataset "$disk_dataset")
    log_msg "------------------------------------------"
    log_msg "Processing disk: ${disk_dataset} -> ${remote_ds} (Label: ${disk_label})"

    # Check if local ZFS snapshot exists
    if ! zfs list -H -o name -t snapshot "${disk_dataset}@${NEW_SNAP}" > /dev/null 2>&1; then
         log_msg "Warning: Local ZFS snapshot ${disk_dataset}@${NEW_SNAP} does not exist. (Disk: ${disk_label})"
         return
    else
         log_msg "Local ZFS snapshot ${disk_dataset}@${NEW_SNAP} exists; proceeding."
    fi

    if [ "$NEW_TYPE" = "full" ]; then
         log_msg "FULL mode: Removing all remote snapshots with prefix 'replicate-' for ${remote_ds}..."
         remote_purge_replica_snapshots "$remote_ds"
         send_full "$disk_dataset" "$remote_ds"
    else
         log_msg "Incremental mode: Starting differential replication for ${disk_dataset}..."
         BASE_SNAP=$(zfs list -H -o name -t snapshot "${disk_dataset}" | grep "^${disk_dataset}@replicate-" | grep -v "@${NEW_SNAP}" | sort -V | tail -n 1 || true)
         if [ -z "$BASE_SNAP" ]; then
              log_msg "No base snapshot found for incremental replication on ${disk_dataset}. Proceeding with FULL replication as fallback."
              remote_purge_replica_snapshots "$remote_ds"
              send_full "$disk_dataset" "$remote_ds"
         else
              log_msg "Base snapshot found: $BASE_SNAP"
              send_flags=$(zfs_send_flags "$disk_dataset")
              if have_pv; then
                  if ! zfs send $send_flags -i "$BASE_SNAP" "${disk_dataset}@${NEW_SNAP}" | pv | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"; then
                       log_msg "Error: Incremental replication for ${disk_dataset} failed, trying fallback FULL replication..."
                       remote_purge_replica_snapshots "$remote_ds"
                       send_full "$disk_dataset" "$remote_ds"
                  fi
              else
                  if ! zfs send $send_flags -i "$BASE_SNAP" "${disk_dataset}@${NEW_SNAP}" | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"; then
                       log_msg "Error: Incremental replication for ${disk_dataset} failed, trying fallback FULL replication..."
                       remote_purge_replica_snapshots "$remote_ds"
                       send_full "$disk_dataset" "$remote_ds"
                  fi
              fi
         fi
    fi

    log_msg "Local ZFS snapshot chain for ${disk_dataset} is preserved."
}

# --- Mirror an Offline VM/CT Directly to the Remote Host (mirror mode) ---
# One-shot full copy of a STOPPED guest. Uses a transient @mirror-* snapshot
# that is destroyed on both sides afterwards. Does not touch the managed
# 'replicate-' chain or retention bookkeeping.
mirror_offline_vm() {
    log_msg "Mode 'mirror' selected: one-shot full mirror of VMID $VMID to ${REMOTE}."

    # 1. Refuse to mirror a running guest: a crash-consistent copy is not a
    #    consistent copy. Stop the guest first, then mirror.
    local status
    status=$(guest_status)
    if [ "$status" != "stopped" ]; then
        log_msg "Error: VMID $VMID is '${status:-unknown}', not 'stopped'. Refusing to mirror a live guest."
        exit 1
    fi

    local mirror_snap="mirror-$(date +'%Y%m%d-%H%M%S')"
    log_msg "Transient snapshot suffix: @${mirror_snap}"

    # 2. Collect disk datasets from the config.
    collect_disk_datasets
    if [ "${#DISK_DATASETS[@]}" -eq 0 ]; then
        log_msg "Error: no disk datasets found for VMID $VMID."
        exit 1
    fi
    log_msg "Disks to mirror: ${DISK_DATASETS[*]}"

    # 3. snapshot -> full send -> destroy transient snapshot, per dataset.
    local ds send_flags remote_ds
    for ds in "${DISK_DATASETS[@]}"; do
        remote_ds=$(remote_dataset "$ds")
        log_msg "------------------------------------------"
        log_msg "Mirroring ${ds} -> ${remote_ds}"

        if ! zfs list -H -o name "$ds" > /dev/null 2>&1; then
            log_msg "Warning: local dataset ${ds} missing, skipping."
            continue
        fi

        zfs snapshot "${ds}@${mirror_snap}"
        send_flags=$(zfs_send_flags "$ds")

        log_msg "Sending ${ds}@${mirror_snap} (full, flags: -p ${send_flags:-})..."
        if have_pv; then
            zfs send -p $send_flags "${ds}@${mirror_snap}" | pv | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"
        else
            zfs send -p $send_flags "${ds}@${mirror_snap}" | $SSH root@"${REMOTE}" zfs receive -F "${remote_ds}"
        fi

        # Clean up the transient snapshot on both sides.
        zfs destroy "${ds}@${mirror_snap}"
        $SSH root@"${REMOTE}" "zfs destroy ${remote_ds}@${mirror_snap} 2>/dev/null || true"
        log_msg "Done: ${ds}"
    done

    # 4. Push the config, then exit. No QM chain, no retention juggling.
    update_remote_config
    log_msg "=========================================="
    log_msg "Offline mirror of VMID $VMID completed successfully."
    exit 0
}

# --- Manage Local QM Snapshot Chain ---
manage_local_qm_chain() {
    local total_count
    total_count=$(echo "$QM_SNAP_LIST" | awk 'NF{print $1}' | grep -c . || true)

    if [ "$total_count" -eq 0 ]; then
        log_msg "No managed QM snapshots present; nothing to prune."
        return
    fi

    if [ "$NEW_TYPE" = "full" ] && [ "$total_count" -gt 1 ]; then
         log_msg "New snapshot is FULL. Deleting all older snapshots from the chain..."
         echo "$QM_SNAP_LIST" | awk 'NF{print $1}' | grep -v "^${NEW_SNAP}$" | while read -r snap; do
             [ -z "$snap" ] && continue
             log_msg "Deleting local QM snapshot $snap"
             qm delsnapshot "$VMID" "$snap"
         done
    else
         log_msg "Local QM snapshot chain is intact ($total_count snapshots present)."
    fi

    if [ "$total_count" -gt "$RETENTION" ]; then
         local num_delete=$(( total_count - RETENTION ))
         log_msg "There are $total_count local replication snapshots. Deleting $num_delete of the oldest..."
         echo "$QM_SNAP_LIST" | awk 'NF{print $1}' | head -n "$num_delete" | while read -r snap; do
             [ -z "$snap" ] && continue
             log_msg "Deleting local QM snapshot $snap"
             qm delsnapshot "$VMID" "$snap"
         done
    else
         log_msg "Local QM snapshot chain is within retention limits ($total_count snapshots)."
    fi
}

# --- Update Remote Configuration ---
update_remote_config() {
    local tmp_config="/tmp/${VMID}.conf.modified"
    # Clean up the temp file even if something below fails.
    trap 'rm -f "$tmp_config"' RETURN

    log_msg "Cleaning up and copying VM configuration to ${REMOTE}..."
    sed -e '/^\[/,$d' -e '/^parent:/d' -e '/^onboot:/ s/.*/onboot: 0/' -e '$a onboot: 0' "${CONFIG_FILE}" > "$tmp_config"
    $SCP "$tmp_config" "root@${REMOTE}:${CONFIG_FILE}"
}

# --- Main Script Execution ---
set -e
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Uncomment the next line for step-by-step debugging:
# set -x

# --- Parse Command-Line Options ---
LOGFILE=""
while [[ "$1" =~ ^- ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -v|--version)
            print_banner
            exit 0
            ;;
        -c|--clear)
            clear_all_snapshots
            ;;
        -l|--log)
            shift
            if [ -z "$1" ]; then
                echo "Error: Log file not specified." >&2
                exit 1
            fi
            LOGFILE="$1"
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            echo >&2
            print_help >&2
            exit 1
            ;;
    esac
    shift
done

# --- No Parameters: Always Show Help (including current variable values) ---
if [ "$#" -lt 1 ]; then
    print_help
    exit 0
fi

# --- Validate Parameter Count ---
if [ "$#" -gt 2 ]; then
    echo "Error: too many arguments." >&2
    echo >&2
    print_help >&2
    exit 1
fi

VMID="$1"
MODE="auto"
if [ "$#" -eq 2 ]; then
    case "$2" in
        full|inc|del|mirror) MODE="$2" ;;
        *)
            echo "Error: unknown mode '$2' (expected: full, inc, del or mirror)." >&2
            echo >&2
            print_help >&2
            exit 1
            ;;
    esac
fi

# --- Acquire Lock (prevents overlapping cron runs for the same VMID) ---
mkdir -p "$LOCKDIR"
LOCKFILE="${LOCKDIR}/zfs_replicate.${VMID}.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log_msg "Another replication run for VMID ${VMID} is already in progress. Exiting."
    exit 1
fi

# --- Get Configuration File ---
CONFIG_FILE=$(get_config_file)
log_msg "=========================================="
log_msg "zfs_replicate.sh $VERSION"
log_msg "Starting replication for VMID: ${VMID}"
log_msg "Local configuration: ${CONFIG_FILE}"
log_msg "Target host: ${REMOTE}:${REMOTE_PORT}"
log_msg "Pools: ${LOCAL_POOL} (local) -> ${REMOTE_POOL} (remote)"
log_msg "Mode: ${MODE}"
log_msg "=========================================="

# --- Handle 'del' Mode (purely local, no remote host required) ---
if [ "$MODE" = "del" ]; then
    delete_local_qm_snapshots
fi

# --- Pre-flight: Verify the Remote Host Before Any Transfer ---
# Every mode below this point (mirror, full, inc, auto) needs the remote host.
check_remote

# --- Handle 'mirror' Mode (one-shot, offline guest) ---
if [ "$MODE" = "mirror" ]; then
    mirror_offline_vm
fi

# --- Get Local QM Snapshot List (Only snapshots with 'replicate-' prefix) ---
QM_SNAP_LIST=$(qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' || true)
log_msg "Local replication QM snapshots unsorted:"
log_msg "$QM_SNAP_LIST"

# --- Determine Replication Mode (Auto) ---
if [ "$MODE" = "auto" ]; then
    determine_replication_mode
else
    NEW_TYPE="$MODE"
    log_msg "Replication mode manually set: New snapshot will be ${NEW_TYPE}."
fi

# --- Create New QM Snapshot ---
create_new_qm_snapshot

# --- Process Disk Entries from VM Configuration ---
collect_disk_datasets
for disk_dataset in "${DISK_DATASETS[@]}"; do
    replicate_disk "$disk_dataset"
done

# --- Manage Local QM Snapshot Chain ---
manage_local_qm_chain

# --- Update Remote VM Configuration (only on full runs, as documented) ---
if [ "$NEW_TYPE" = "full" ]; then
    update_remote_config
else
    log_msg "Incremental run: remote VM configuration left unchanged."
fi

log_msg "=========================================="
log_msg "Replication for VMID ${VMID} completed successfully."
exit 0
