#!/bin/bash
#
# zfs_replicate.sh Version 2.0
#
# Script for replicating ZFS datasets of a VM from a local Proxmox VE to a remote Proxmox VE.
#
# This script supports both automatic mode selection and explicit modes:
#    zfs_replicate.sh <VMID> full   -> Forces a FULL replication (e.g., weekly via cron;
#                                      deletes remote snapshots and updates the VM configuration).
#    zfs_replicate.sh <VMID> inc    -> Forces an incremental replication (e.g., every few hours).
#    zfs_replicate.sh <VMID> del    -> Deletes all local QM snapshots with the prefix "replicate-"
#                                      without transferring.
#
# Snapshot names must strictly follow the format:
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
# Author: Kilowatt
# Origin: Patrick (Striker2102)
# Date: 14.03.2025
#

# --- Basic Settings ---
REMOTE="YOUR_SERVER_HERE"
RETENTION=5
VERSION="250314_2.0"

# --- Usage Message ---
USAGE=$(cat <<'EOF'
Usage: zfs_replicate.sh [OPTIONS] <VMID> [full|inc|del]

Script for replicating ZFS datasets from a local Proxmox VE to a remote host.

Modes:
  full   Force a FULL replication (e.g., weekly via cron; deletes remote snapshots and updates VM config).
  inc    Force an incremental replication (e.g., every few hours).
  del    Delete all local QM snapshots with the prefix "replicate-" without transferring.

Options:
  -h, --help           Show this help message.
  -v, --version        Show the version.
  -c, --clear          Delete all replica snapshots in the pool.
  -l, --log <file>     Append output to the specified log file instead of printing to screen.

Note:
  Snapshot names must follow the format:
    replicate-YYYYMMDD-HHMMSS-full
    replicate-YYYYMMDD-HHMMSS-inc

Manually created QM snapshots (without the "replicate-" prefix) remain untouched.
EOF
)

# --- Logging Function ---
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

# --- Clear All Replica Snapshots in Pool ---
clear_all_snapshots() {
    log_msg "Version: $VERSION"
    log_msg "Clearing all snapshots created by this script from the pool."
    for snapshot in $(zfs list -H -t snapshot | grep replica | cut -f 1); do
         sudo zfs destroy "$snapshot"
    done
    exit 0
}

# --- Delete Local QM Snapshots (del mode) ---
delete_local_qm_snapshots() {
    log_msg "Mode 'del' selected: Deleting all local QM snapshots with prefix 'replicate-' for VMID $VMID."
    local qm_snap_list
    qm_snap_list=$(qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' || true)
    log_msg "Found QM snapshots:"
    log_msg "$qm_snap_list"
    echo "$qm_snap_list" | awk '{print $1}' | while read -r snap; do
         log_msg "Deleting QM snapshot $snap..."
         qm delsnapshot "$VMID" "$snap"
    done
    log_msg "All local QM snapshots have been deleted."
    exit 0
}

# --- Determine VM Configuration File ---
get_config_file() {
    local vm_config_file="/etc/pve/qemu-server/${VMID}.conf"
    local lxc_config_file="/etc/pve/lxc/${VMID}.conf"

    if [ -f "$vm_config_file" ]; then
        echo "$vm_config_file"
    else
        log_msg "$VMID appears to be an LXC container; switching config path."
        if [ -f "$lxc_config_file" ]; then
            echo "$lxc_config_file"
        else
            log_msg "Error: Configuration file not found for VMID ${VMID}!"
            exit 1
        fi
    fi
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
    QM_SNAP_LIST=$(qm listsnapshot "$VMID" | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' | sort -V)
    log_msg "Updated QM snapshot list:"
    log_msg "$QM_SNAP_LIST"
}

# --- Replicate Disk for a Given Dataset ---
replicate_disk() {
    local disk_dataset="$1"
    local disk_label
    disk_label=$(basename "$disk_dataset")
    log_msg "------------------------------------------"
    log_msg "Processing disk: ${disk_dataset} (Label: ${disk_label})"

    # Check if local ZFS snapshot exists
    if ! zfs list -H -o name -t snapshot "${disk_dataset}@${NEW_SNAP}" > /dev/null 2>&1; then
         log_msg "Warning: Local ZFS snapshot ${disk_dataset}@${NEW_SNAP} does not exist. (Disk: ${disk_label})"
         return
    else
         log_msg "Local ZFS snapshot ${disk_dataset}@${NEW_SNAP} exists; proceeding."
    fi

    if [ "$NEW_TYPE" = "full" ]; then
         log_msg "FULL mode: Removing all remote snapshots with prefix 'replicate-' for ${disk_dataset}..."
         ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do
             echo \"Deleting remote snapshot \$snap\";
             zfs destroy -R \"\$snap\";
         done" || log_msg "No remote snapshots to delete or an error occurred."

         log_msg "Sending FULL ZFS snapshot ${disk_dataset}@${NEW_SNAP}..."
         zfs send -V "${disk_dataset}@${NEW_SNAP}" | pv | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
    else
         log_msg "Incremental mode: Starting differential replication for ${disk_dataset}..."
         BASE_SNAP=$(zfs list -H -o name -t snapshot "${disk_dataset}" | grep "^${disk_dataset}@replicate-" | grep -v "@${NEW_SNAP}" | sort -V | tail -n 1 || true)
         if [ -z "$BASE_SNAP" ]; then
              log_msg "No base snapshot found for incremental replication on ${disk_dataset}. Proceeding with FULL replication as fallback."
              ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do
                  echo \"Deleting remote snapshot \$snap\";
                  zfs destroy -R \"\$snap\";
              done" || log_msg "Error during remote snapshot deletion (fallback)."
              log_msg "Sending FULL ZFS snapshot ${disk_dataset}@${NEW_SNAP}..."
              zfs send -V "${disk_dataset}@${NEW_SNAP}" | pv | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
         else
              log_msg "Base snapshot found: $BASE_SNAP"
              if ! zfs send -i "$BASE_SNAP" "${disk_dataset}@${NEW_SNAP}" | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"; then
                   log_msg "Error: Incremental replication for ${disk_dataset} failed, trying fallback FULL replication..."
                   ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do
                       echo \"Deleting remote snapshot \$snap\";
                       zfs destroy -R \"\$snap\";
                   done" || log_msg "Error during remote snapshot deletion (fallback)."
                   log_msg "Sending FULL ZFS snapshot ${disk_dataset}@${NEW_SNAP}..."
                   zfs send -V "${disk_dataset}@${NEW_SNAP}" | pv | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
              fi
         fi
    fi

    log_msg "Local ZFS snapshot chain for ${disk_dataset} is preserved."
}

# --- Manage Local QM Snapshot Chain ---
manage_local_qm_chain() {
    local total_count
    total_count=$(echo "$QM_SNAP_LIST" | awk '{print $1}' | wc -l)
    if [ "$NEW_TYPE" = "full" ] && [ "$total_count" -gt 1 ]; then
         log_msg "New snapshot is FULL. Deleting all older FULL snapshots from the chain..."
         echo "$QM_SNAP_LIST" | awk '{print $1}' | grep -v "^${NEW_SNAP}$" | while read -r snap; do
             log_msg "Deleting local FULL QM snapshot $snap"
             qm delsnapshot "$VMID" "$snap"
         done
    else
         log_msg "Local QM snapshot chain is intact ($total_count snapshots present)."
    fi

    if [ "$total_count" -gt "$RETENTION" ]; then
         local num_delete=$(( total_count - RETENTION ))
         log_msg "There are $total_count local replication snapshots. Deleting $num_delete of the oldest..."
         echo "$QM_SNAP_LIST" | awk '{print $1}' | head -n "$num_delete" | while read -r snap; do
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
    log_msg "Cleaning up and copying VM configuration to ${REMOTE}..."
    sed -e '/^\[/,$d' -e '/^parent:/d' -e '/^onboot:/ s/.*/onboot: 0/' -e '$a onboot: 0' "${CONFIG_FILE}" > "$tmp_config"
    scp "$tmp_config" "root@${REMOTE}:${CONFIG_FILE}"
    rm -f "$tmp_config"
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
            echo "$USAGE"
            exit 0
            ;;
        -v|--version)
            echo "$VERSION"
            exit 0
            ;;
        -c|--clear)
            clear_all_snapshots
            ;;
        -l|--log)
            shift
            if [ -z "$1" ]; then
                echo "Error: Log file not specified."
                exit 1
            fi
            LOGFILE="$1"
            ;;
        *)
            echo "Unknown option: $1"
            echo "$USAGE"
            exit 1
            ;;
    esac
    shift
done

# --- Validate Required Parameters ---
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "$USAGE"
    exit 1
fi

VMID="$1"
MODE="auto"
if [ "$#" -eq 2 ]; then
    if [ "$2" = "full" ] || [ "$2" = "inc" ] || [ "$2" = "del" ]; then
        MODE="$2"
    else
        echo "$USAGE"
        exit 1
    fi
fi

# --- Get Configuration File ---
CONFIG_FILE=$(get_config_file)
log_msg "=========================================="
log_msg "Starting replication for VMID: ${VMID}"
log_msg "Local configuration: ${CONFIG_FILE}"
log_msg "Target host: ${REMOTE}"
log_msg "=========================================="

# --- Handle 'del' Mode ---
if [ "$MODE" = "del" ]; then
    delete_local_qm_snapshots
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
# Read all disk entries (only from the main part of the configuration, before the first '[')
readarray -t disk_lines < <(sed '/^\[/q' "${CONFIG_FILE}" | grep -E '^[[:space:]]*(scsi|sata|virtio|efidisk|tpmstate)[0-9]+:')
log_msg "Found ${#disk_lines[@]} disk entries."

for line in "${disk_lines[@]}"; do
    log_msg "Processing config line: $line"
    # Extract dataset from the disk entry
    disk_dataset=$(echo "$line" | sed -E 's/^[a-z]+[0-9]+:\s*([^,]+).*/\1/')
    if [ "$disk_dataset" = "none" ]; then
         log_msg "Skipping invalid disk entry: $line"
         continue
    fi
    # Replace ':' with '/' to form the dataset path
    disk_dataset=$(echo "$disk_dataset" | sed 's/:/\//g')
    replicate_disk "$disk_dataset"
done

# --- Manage Local QM Snapshot Chain ---
manage_local_qm_chain

# --- Update Remote VM Configuration ---
update_remote_config

log_msg "=========================================="
log_msg "Replication for VMID ${VMID} completed successfully."
exit 0
