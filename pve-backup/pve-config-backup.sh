#!/usr/bin/env bash
#
# pve-config-backup.sh
# -----------------------------------------------------------------------------
# Sichert die "wichtigen" Konfigurationsdateien eines Proxmox-VE-Hosts in ein
# ZIP-Archiv und schiebt dieses optional per SSH auf einen anderen Server.
#
# Was hier NICHT passiert: ein vollwertiges Bare-Metal-Image. Das ist Aufgabe
# von Clonezilla, ZFS send/recv oder dem Proxmox Backup Server. Dieses Script
# rettet die Nervenarbeit (Netzwerk, Storage-Definitionen, VM-/CT-Configs,
# PCI-Passthrough-Gefrickel), nicht die Bytes der Gäste.
#
# Restore-Hinweis: /etc/pve ist das pmxcfs-Cluster-Dateisystem. Dateien daraus
# wirft man NICHT blind zurück auf einen frisch installierten Host. Erst lesen,
# dann denken, dann selektiv kopieren. Das Archiv ist eine Referenz, kein
# "tar -x und gut".
# -----------------------------------------------------------------------------
set -euo pipefail

# ============================ DEFAULT-WERTE =================================
DEFAULT_PREFIX="pve-config"
DEFAULT_TMPDIR="/tmp"
DEFAULT_SSH_PORT="22"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Konfigurierbare Variablen (per CLI ueberschreibbar)
PREFIX="$DEFAULT_PREFIX"
OUTFILE=""                       # wird unten aus PREFIX/Hostname/Timestamp gebaut
TMPDIR="$DEFAULT_TMPDIR"
DEST=""                          # z.B. user@backup-host:/srv/pve-backups/
SSH_PORT="$DEFAULT_SSH_PORT"
SSH_KEY=""
USE_RSYNC=0
KEEP_LOCAL=0
NO_TRANSFER=0
QUIET=0
declare -a EXTRA_PATHS=()

# ===================== STANDARD-SICHERUNGSUMFANG ============================
# Alles was ein PVE-Host braucht, um nach einer Neuinstallation nicht wie ein
# frisch geborenes Kaelbchen dazustehen. Nicht-existente Pfade werden spaeter
# stillschweigend uebersprungen - nicht jeder Host hat jede Datei.
BACKUP_PATHS=(
  "/etc/pve"                       # Herzstueck: VM-/CT-/Storage-/Cluster-Config
  "/etc/network/interfaces"        # Netzwerk
  "/etc/network/interfaces.d"
  "/etc/hostname"
  "/etc/hosts"
  "/etc/resolv.conf"
  "/etc/timezone"
  "/etc/fstab"                     # Mountpoints
  "/etc/default/grub"              # Boot-Parameter (IOMMU & Co.)
  "/etc/default/grub.d"
  "/etc/kernel/cmdline"            # systemd-boot Aequivalent zu grub cmdline
  "/etc/modules"                   # geladene Kernel-Module (vfio etc.)
  "/etc/modprobe.d"                # Passthrough-Blacklists, vfio-pci ids
  "/etc/lvm"                       # LVM-Konfiguration
  "/etc/vzdump.conf"               # Backup-Defaults
  "/etc/sysctl.conf"
  "/etc/sysctl.d"
  "/etc/ksmtuned.conf"
  "/etc/aliases"
  "/etc/cron.d"
  "/etc/cron.daily"
  "/etc/cron.hourly"
  "/etc/cron.weekly"
  "/etc/cron.monthly"
  "/etc/crontab"
  "/etc/ssh"                       # SSH-Server-Config + Host-Keys
  "/etc/apt/sources.list"          # Repos
  "/etc/apt/sources.list.d"
  "/etc/apt/auth.conf.d"
  "/etc/passwd"                    # Debian-Userland - gehoert dazu, sonst
  "/etc/group"                     #   passen UID/GID nach Restore nicht mehr
  "/etc/shadow"
  "/etc/gshadow"
  "/etc/subuid"                    # wichtig fuer unprivilegierte LXC
  "/etc/subgid"
  "/etc/systemd/network"
  "/etc/systemd/system"            # eigene Units / Overrides
)

# pmxcfs-Datenbank: die "echte" Quelle von /etc/pve. Wird separat gedumpt.
PMXCFS_DB="/var/lib/pve-cluster/config.db"

# ============================== LOGGING =====================================
log()  { [[ "$QUIET" -eq 1 ]] || echo -e "[\e[32m*\e[0m] $*"; }
warn() { echo -e "[\e[33m!\e[0m] $*" >&2; }
die()  { echo -e "[\e[31mx\e[0m] $*" >&2; exit 1; }

# ============================== USAGE =======================================
usage() {
cat <<EOF
pve-config-backup.sh - Konfigurations-Backup fuer Proxmox-VE-Hosts

VERWENDUNG:
  $(basename "$0") [OPTIONEN]

OPTIONEN:
  -o, --output DATEI      Voller Pfad/Name der ZIP-Datei.
                          Default: <tmpdir>/<prefix>-<hostname>-<timestamp>.zip
  -p, --prefix NAME       Dateinamen-Praefix.            Default: ${DEFAULT_PREFIX}
  -t, --tmpdir VERZ       Arbeits-/Ablageverzeichnis.    Default: ${DEFAULT_TMPDIR}
  -d, --dest ZIEL         SSH-Ziel fuer die Uebertragung,
                          Format: user@host:/pfad/       (sonst kein Transfer)
  -P, --port PORT         SSH-Port.                      Default: ${DEFAULT_SSH_PORT}
  -i, --identity DATEI    SSH-Private-Key fuer die Uebertragung.
  -r, --rsync             rsync statt scp fuer den Transfer verwenden.
  -e, --extra PFAD        Zusaetzlicher Pfad im Backup (mehrfach nutzbar).
  -k, --keep-local        Lokale ZIP-Datei nach Transfer NICHT loeschen.
  -n, --no-transfer       Nur lokal sichern, nichts uebertragen.
  -q, --quiet             Nur Warnungen/Fehler ausgeben.
  -h, --help              Diese Hilfe anzeigen.

BEISPIELE:
  # Nur lokales Backup nach /tmp:
  $(basename "$0") -n

  # Backup erstellen und per scp auf den Backup-Host schieben:
  $(basename "$0") -d backup@nas.local:/srv/pve-backups/

  # Mit eigenem Key, Port 2222, rsync und zusaetzlichem Pfad:
  $(basename "$0") -d root@10.0.0.9:/backups/ -P 2222 -i ~/.ssh/backup \\
                   -r -e /etc/iscsi -e /root/scripts

EXIT-CODES:
  0  alles gut    1  Fehler    2  Aufruffehler (falsche Parameter)
EOF
}

# ========================= ARGUMENT-PARSING =================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUTFILE="${2:?--output braucht ein Argument}"; shift 2;;
    -p|--prefix)    PREFIX="${2:?--prefix braucht ein Argument}"; shift 2;;
    -t|--tmpdir)    TMPDIR="${2:?--tmpdir braucht ein Argument}"; shift 2;;
    -d|--dest)      DEST="${2:?--dest braucht ein Argument}"; shift 2;;
    -P|--port)      SSH_PORT="${2:?--port braucht ein Argument}"; shift 2;;
    -i|--identity)  SSH_KEY="${2:?--identity braucht ein Argument}"; shift 2;;
    -r|--rsync)     USE_RSYNC=1; shift;;
    -e|--extra)     EXTRA_PATHS+=("${2:?--extra braucht ein Argument}"); shift 2;;
    -k|--keep-local) KEEP_LOCAL=1; shift;;
    -n|--no-transfer) NO_TRANSFER=1; shift;;
    -q|--quiet)     QUIET=1; shift;;
    -h|--help)      usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 2;;
  esac
done

# Output-Datei aus Defaults bauen, falls nicht explizit gesetzt
if [[ -z "$OUTFILE" ]]; then
  OUTFILE="${TMPDIR%/}/${PREFIX}-${HOSTNAME_SHORT}-${TIMESTAMP}.zip"
fi

# ========================= VORAB-PRUEFUNGEN =================================
[[ "$(id -u)" -eq 0 ]] || die "Root-Rechte noetig. /etc/shadow liest sich nicht von selbst."

command -v zip >/dev/null 2>&1 || \
  die "'zip' ist nicht installiert. Abhilfe:  apt-get install -y zip"

if ! command -v pveversion >/dev/null 2>&1; then
  warn "Das hier sieht nicht nach einem PVE-Host aus ('pveversion' fehlt)."
  warn "Script laeuft trotzdem weiter - aber erwarte keine Wunder."
fi

[[ -d "$TMPDIR" ]] || die "Arbeitsverzeichnis existiert nicht: $TMPDIR"

if [[ "$NO_TRANSFER" -eq 0 && -z "$DEST" ]]; then
  warn "Kein --dest angegeben -> es wird nur lokal gesichert (wie bei -n)."
  NO_TRANSFER=1
fi

# ===================== STAGING-VERZEICHNIS ANLEGEN ==========================
STAGING="$(mktemp -d "${TMPDIR%/}/pve-cfg-stage.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

log "Sammle Konfiguration von '${HOSTNAME_SHORT}' ..."

# Pfade ins Staging kopieren - Struktur erhalten, Symlinks aufloesen,
# Nicht-Vorhandenes elegant ignorieren.
ALL_PATHS=("${BACKUP_PATHS[@]}" "${EXTRA_PATHS[@]}")
copied=0 skipped=0
for path in "${ALL_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    parent="$(dirname "$path")"
    mkdir -p "${STAGING}${parent}"
    if cp -aL --parents "$path" "$STAGING" 2>/dev/null; then
      copied=$((copied+1))
    else
      # Fallback ohne Dereferenzierung (z.B. tote Symlinks)
      cp -a --parents "$path" "$STAGING" 2>/dev/null \
        && copied=$((copied+1)) \
        || { warn "Konnte nicht sichern: $path"; skipped=$((skipped+1)); }
    fi
  else
    skipped=$((skipped+1))
  fi
done
log "Kopiert: ${copied} Pfade, uebersprungen: ${skipped} (nicht vorhanden o. unlesbar)."

# pmxcfs-Datenbank separat sichern - das ist die Wahrheit hinter /etc/pve.
mkdir -p "${STAGING}/pve-cluster"
if [[ -f "$PMXCFS_DB" ]]; then
  cp -a "$PMXCFS_DB" "${STAGING}/pve-cluster/config.db"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$PMXCFS_DB" .dump > "${STAGING}/pve-cluster/config.db.sql" 2>/dev/null \
      && log "pmxcfs-Datenbank gesichert (Rohdatei + SQL-Dump)." \
      || log "pmxcfs-Datenbank gesichert (nur Rohdatei, SQL-Dump fehlgeschlagen)."
  else
    log "pmxcfs-Datenbank gesichert (Rohdatei; 'sqlite3' fuer SQL-Dump fehlt)."
  fi
else
  warn "pmxcfs-Datenbank ${PMXCFS_DB} nicht gefunden - kein Cluster-Host?"
fi

# ===================== SYSTEM-INVENTAR / MANIFEST ===========================
# Ein Stueck Papier fuer das spaetere Ich, das beim Restore verzweifelt.
MANIFEST="${STAGING}/BACKUP-MANIFEST.txt"
{
  echo "PVE Konfigurations-Backup"
  echo "========================="
  echo "Host         : $(hostname -f 2>/dev/null || hostname)"
  echo "Erstellt am  : $(date -Is)"
  echo "Erstellt von : $(basename "$0")"
  echo
  echo "--- pveversion ---"
  command -v pveversion >/dev/null 2>&1 && pveversion -v 2>/dev/null || echo "n/a"
  echo
  echo "--- Storage (pvesm status) ---"
  command -v pvesm >/dev/null 2>&1 && pvesm status 2>/dev/null || echo "n/a"
  echo
  echo "--- VMs (qm list) ---"
  command -v qm >/dev/null 2>&1 && qm list 2>/dev/null || echo "n/a"
  echo
  echo "--- Container (pct list) ---"
  command -v pct >/dev/null 2>&1 && pct list 2>/dev/null || echo "n/a"
  echo
  echo "--- Netzwerk (ip -br addr) ---"
  ip -br addr 2>/dev/null || echo "n/a"
  echo
  echo "--- Block-Devices (lsblk) ---"
  lsblk 2>/dev/null || echo "n/a"
} > "$MANIFEST"
log "System-Inventar nach BACKUP-MANIFEST.txt geschrieben."

# ============================ ZIP ERSTELLEN ================================
log "Erstelle Archiv: ${OUTFILE}"
mkdir -p "$(dirname "$OUTFILE")"
( cd "$STAGING" && zip -r -q -y "$OUTFILE" . ) \
  || die "zip ist gescheitert. Kein Archiv, kein Backup, kein Glueck."

# Pruefsumme erzeugen - Vertrauen ist gut, sha256 ist besser.
CHECKSUM_FILE="${OUTFILE}.sha256"
sha256sum "$OUTFILE" | awk '{print $1"  "FILENAME_BASE}' \
  FILENAME_BASE="$(basename "$OUTFILE")" > "$CHECKSUM_FILE"

SIZE_HUMAN="$(du -h "$OUTFILE" | cut -f1)"
log "Archiv fertig: ${OUTFILE} (${SIZE_HUMAN})"
log "Pruefsumme   : ${CHECKSUM_FILE}"

# ============================ UEBERTRAGUNG =================================
if [[ "$NO_TRANSFER" -eq 1 ]]; then
  log "Kein Transfer gewuenscht. Archiv liegt lokal bereit."
  KEEP_LOCAL=1
else
  log "Uebertrage Archiv nach: ${DEST}"

  # SSH-Optionen zusammenbauen
  SSH_OPTS=( -p "$SSH_PORT" )
  [[ -n "$SSH_KEY" ]] && SSH_OPTS+=( -i "$SSH_KEY" )

  if [[ "$USE_RSYNC" -eq 1 ]]; then
    command -v rsync >/dev/null 2>&1 || die "rsync angefordert, aber nicht installiert."
    RSYNC_SSH="ssh -p ${SSH_PORT}"
    [[ -n "$SSH_KEY" ]] && RSYNC_SSH="${RSYNC_SSH} -i ${SSH_KEY}"
    rsync -a --progress -e "$RSYNC_SSH" \
          "$OUTFILE" "$CHECKSUM_FILE" "$DEST" \
      || die "rsync-Transfer fehlgeschlagen. Archiv bleibt lokal erhalten."
  else
    scp "${SSH_OPTS[@]}" "$OUTFILE" "$CHECKSUM_FILE" "$DEST" \
      || die "scp-Transfer fehlgeschlagen. Archiv bleibt lokal erhalten."
  fi
  log "Transfer erfolgreich abgeschlossen."

  # Lokales Aufraeumen (sofern nicht gewuenscht behalten)
  if [[ "$KEEP_LOCAL" -eq 0 ]]; then
    rm -f "$OUTFILE" "$CHECKSUM_FILE"
    log "Lokale Kopie entfernt (--keep-local zum Behalten)."
  else
    log "Lokale Kopie behalten: ${OUTFILE}"
  fi
fi

log "Fertig. Der zukuenftige Admin dankt dir bereits."
exit 0
