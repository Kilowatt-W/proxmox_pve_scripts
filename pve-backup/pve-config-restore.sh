#!/usr/bin/env bash
#
# pve-config-restore.sh
# -----------------------------------------------------------------------------
# Gegenstueck zu pve-config-backup.sh: holt ein ZIP-Konfigurations-Archiv
# (lokal oder per SSH), prueft die Pruefsumme, entpackt es in ein Staging-
# Verzeichnis und stellt - auf ausdrueckliche Anweisung - einzelne Pfade
# kontrolliert wieder her.
#
# WICHTIG, bitte einmal nuechtern lesen:
#   * Der Default-Modus restauriert NICHTS. Er entpackt und zeigt nur an.
#     Das ist Absicht. Ein Restore-Script, das ungefragt /etc ueberschreibt,
#     ist kein Werkzeug, sondern eine Falle.
#   * /etc/pve ist das pmxcfs-Cluster-Dateisystem. Dateien dort blind
#     zurueckzukopieren kann Node oder Cluster zerlegen. In einem Cluster
#     synchronisiert sich /etc/pve beim Rejoin ohnehin selbst. Deshalb ist
#     das Zurueckspielen von /etc/pve-Pfaden hinter --allow-pve verriegelt.
#   * Restore-Ziel ist idealerweise ein frisch installierter Host gleicher
#     PVE-Version. Hardware-abhaengige Dinge (NIC-Namen!) vorher pruefen.
# -----------------------------------------------------------------------------
set -euo pipefail

# ============================ DEFAULT-WERTE =================================
DEFAULT_TMPDIR="/tmp"
DEFAULT_SSH_PORT="22"

INPUT=""                 # lokales Archiv
FROM=""                  # SSH-Quelle user@host:/pfad/archiv.zip
TMPDIR="$DEFAULT_TMPDIR"
SSH_PORT="$DEFAULT_SSH_PORT"
SSH_KEY=""
DO_LIST=0
DO_DIFF=0
ASSUME_YES=0
ALLOW_PVE=0
SKIP_CHECKSUM=0
QUIET=0
declare -a APPLY_PATHS=()

# ============================== LOGGING =====================================
log()  { [[ "$QUIET" -eq 1 ]] || echo -e "[\e[32m*\e[0m] $*"; }
warn() { echo -e "[\e[33m!\e[0m] $*" >&2; }
die()  { echo -e "[\e[31mx\e[0m] $*" >&2; exit 1; }

# ============================== USAGE =======================================
usage() {
cat <<EOF
pve-config-restore.sh - Konfigurations-Restore fuer Proxmox-VE-Hosts

VERWENDUNG:
  $(basename "$0") (-i ARCHIV | -f SSH-QUELLE) [OPTIONEN]

QUELLE (genau eine angeben):
  -i, --input DATEI       Lokales ZIP-Archiv von pve-config-backup.sh.
  -f, --from SSH-QUELLE   Archiv per SSH holen, Format: user@host:/pfad/x.zip

OPTIONEN:
  -P, --port PORT         SSH-Port fuer --from.          Default: ${DEFAULT_SSH_PORT}
  -I, --identity DATEI    SSH-Private-Key fuer --from.
  -t, --tmpdir VERZ       Arbeitsverzeichnis.            Default: ${DEFAULT_TMPDIR}
  -l, --list              Archivinhalt auflisten und beenden.
  -D, --diff              Archiv gegen das laufende System diffen.
  -a, --apply PFAD        Diesen Pfad aus dem Archiv wiederherstellen
                          (mehrfach nutzbar, z.B. -a /etc/network/interfaces).
      --allow-pve         Erlaubt --apply auch fuer Pfade unter /etc/pve.
                          Ohne diese Flag werden /etc/pve-Pfade verweigert.
      --no-checksum       Pruefsummen-Check ueberspringen (nicht empfohlen).
  -y, --yes               Rueckfragen vor dem Wiederherstellen unterdruecken.
  -q, --quiet             Nur Warnungen/Fehler ausgeben.
  -h, --help              Diese Hilfe anzeigen.

VERHALTEN OHNE --apply:
  Archiv wird geholt, geprueft und entpackt - mehr nicht. Das Staging-
  Verzeichnis wird ausgegeben, damit du selbst hineinschauen kannst.
  Nichts am laufenden System wird angefasst.

WIEDERHERSTELLUNG MIT --apply:
  Vor dem Ueberschreiben wird die aktuelle Datei/Verzeichnis nach
  <ziel>.bak-<timestamp> gesichert. Danach wird der Inhalt aus dem
  Archiv an die Originalstelle kopiert.

BEISPIELE:
  # Archiv nur entpacken und anschauen:
  $(basename "$0") -i /tmp/pve-config-pve01-20260518-021500.zip

  # Archiv vom Backup-Host holen und gegen das System diffen:
  $(basename "$0") -f backup@nas.local:/srv/pve-backups/pve-config-pve01.zip -D

  # Netzwerk- und GRUB-Konfiguration gezielt zurueckspielen:
  $(basename "$0") -i ./pve-config-pve01.zip \\
                   -a /etc/network/interfaces -a /etc/default/grub -y

  # Einen /etc/pve-Pfad zurueckspielen (nur wenn du WIRKLICH weisst, was du tust):
  $(basename "$0") -i ./pve-config-pve01.zip -a /etc/pve/storage.cfg --allow-pve

EXIT-CODES:
  0  alles gut    1  Fehler    2  Aufruffehler (falsche Parameter)
EOF
}

# ========================= ARGUMENT-PARSING =================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)     INPUT="${2:?--input braucht ein Argument}"; shift 2;;
    -f|--from)      FROM="${2:?--from braucht ein Argument}"; shift 2;;
    -P|--port)      SSH_PORT="${2:?--port braucht ein Argument}"; shift 2;;
    -I|--identity)  SSH_KEY="${2:?--identity braucht ein Argument}"; shift 2;;
    -t|--tmpdir)    TMPDIR="${2:?--tmpdir braucht ein Argument}"; shift 2;;
    -l|--list)      DO_LIST=1; shift;;
    -D|--diff)      DO_DIFF=1; shift;;
    -a|--apply)     APPLY_PATHS+=("${2:?--apply braucht ein Argument}"); shift 2;;
    --allow-pve)    ALLOW_PVE=1; shift;;
    --no-checksum)  SKIP_CHECKSUM=1; shift;;
    -y|--yes)       ASSUME_YES=1; shift;;
    -q|--quiet)     QUIET=1; shift;;
    -h|--help)      usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 2;;
  esac
done

# ========================= VORAB-PRUEFUNGEN =================================
[[ "$(id -u)" -eq 0 ]] || die "Root-Rechte noetig - sonst wird das nichts mit /etc."
command -v unzip >/dev/null 2>&1 || die "'unzip' fehlt. Abhilfe:  apt-get install -y unzip"

if [[ -z "$INPUT" && -z "$FROM" ]]; then
  die "Keine Quelle angegeben. Entweder --input oder --from verwenden."
fi
if [[ -n "$INPUT" && -n "$FROM" ]]; then
  die "--input UND --from gesetzt. Entscheide dich fuer eine Quelle."
fi
[[ -d "$TMPDIR" ]] || die "Arbeitsverzeichnis existiert nicht: $TMPDIR"

if ! command -v pveversion >/dev/null 2>&1; then
  warn "'pveversion' fehlt - das hier ist offenbar kein PVE-Host."
  warn "Restore laeuft trotzdem, aber das Ergebnis ist dann deine Verantwortung."
fi

# ===================== STAGING-VERZEICHNIS ANLEGEN ==========================
WORKDIR="$(mktemp -d "${TMPDIR%/}/pve-cfg-restore.XXXXXX")"
EXTRACT="${WORKDIR}/extracted"
mkdir -p "$EXTRACT"
cleanup() { [[ "${KEEP_WORKDIR:-0}" -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT

# =========================== ARCHIV BESCHAFFEN ==============================
if [[ -n "$FROM" ]]; then
  log "Hole Archiv per SSH von: ${FROM}"
  SCP_OPTS=( -P "$SSH_PORT" )
  [[ -n "$SSH_KEY" ]] && SCP_OPTS+=( -i "$SSH_KEY" )
  scp "${SCP_OPTS[@]}" "$FROM" "${WORKDIR}/" \
    || die "scp-Download fehlgeschlagen. Quelle/Key/Port pruefen."
  # Pruefsummendatei mitnehmen, falls vorhanden (Fehler hier ist nicht fatal)
  scp "${SCP_OPTS[@]}" "${FROM}.sha256" "${WORKDIR}/" 2>/dev/null \
    && log "Pruefsummendatei mitgeholt." \
    || warn "Keine .sha256 zum Archiv gefunden - Integritaetscheck entfaellt."
  ARCHIVE="${WORKDIR}/$(basename "$FROM")"
else
  [[ -f "$INPUT" ]] || die "Archiv nicht gefunden: $INPUT"
  ARCHIVE="$INPUT"
fi
log "Archiv: ${ARCHIVE}"

# ========================= PRUEFSUMME PRUEFEN ===============================
CHECKSUM_FILE="${ARCHIVE}.sha256"
if [[ "$SKIP_CHECKSUM" -eq 1 ]]; then
  warn "Pruefsummen-Check uebersprungen (--no-checksum). Mutig."
elif [[ -f "$CHECKSUM_FILE" ]]; then
  log "Pruefe Pruefsumme ..."
  ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$CHECKSUM_FILE")" >/dev/null ) \
    && log "Pruefsumme OK - Archiv ist unversehrt." \
    || die "PRUEFSUMME FALSCH. Archiv ist beschaedigt oder manipuliert. Abbruch."
else
  warn "Keine Pruefsummendatei (${CHECKSUM_FILE}) - Integritaet nicht verifizierbar."
fi

# ============================ NUR AUFLISTEN =================================
if [[ "$DO_LIST" -eq 1 ]]; then
  log "Inhalt des Archivs:"
  unzip -l "$ARCHIVE"
  KEEP_WORKDIR=0
  exit 0
fi

# ============================== ENTPACKEN ==================================
log "Entpacke Archiv nach: ${EXTRACT}"
unzip -q -o "$ARCHIVE" -d "$EXTRACT" || die "Entpacken fehlgeschlagen."

# Manifest anzeigen, sofern vorhanden - der Spickzettel des Backup-Laufs.
if [[ -f "${EXTRACT}/BACKUP-MANIFEST.txt" ]]; then
  log "Backup-Manifest gefunden:"
  echo "-----------------------------------------------------------------------"
  sed 's/^/    /' "${EXTRACT}/BACKUP-MANIFEST.txt"
  echo "-----------------------------------------------------------------------"
fi

# =============================== DIFF-MODUS =================================
if [[ "$DO_DIFF" -eq 1 ]]; then
  log "Vergleiche Archiv mit dem laufenden System (nur regulaere Dateien) ..."
  diff_count=0
  while IFS= read -r -d '' arcfile; do
    rel="${arcfile#$EXTRACT/}"
    # Meta-Dateien des Backups ueberspringen
    case "$rel" in
      BACKUP-MANIFEST.txt|pve-cluster/*) continue;;
    esac
    livefile="/${rel}"
    if [[ -f "$livefile" ]]; then
      if ! diff -q "$livefile" "$arcfile" >/dev/null 2>&1; then
        echo -e "  \e[33m~ geaendert\e[0m : ${livefile}"
        diff_count=$((diff_count+1))
      fi
    else
      echo -e "  \e[36m+ nur im Archiv\e[0m : ${livefile}"
      diff_count=$((diff_count+1))
    fi
  done < <(find "$EXTRACT" -type f -print0)
  [[ "$diff_count" -eq 0 ]] && log "Keine Unterschiede gefunden." \
                            || log "${diff_count} Datei(en) weichen ab (siehe oben)."
fi

# ===================== SELEKTIVE WIEDERHERSTELLUNG ==========================
if [[ "${#APPLY_PATHS[@]}" -eq 0 ]]; then
  KEEP_WORKDIR=1
  log "Kein --apply angegeben - es wurde nichts veraendert."
  log "Entpacktes Archiv liegt zur Inspektion hier: ${EXTRACT}"
  log "(Verzeichnis bleibt erhalten; bei Bedarf selbst aufraeumen.)"
  exit 0
fi

RESTORE_TS="$(date +%Y%m%d-%H%M%S)"
applied=0
for target in "${APPLY_PATHS[@]}"; do
  # Quelle im Archiv ermitteln (fuehrenden Slash entfernen)
  src="${EXTRACT}/${target#/}"

  if [[ ! -e "$src" ]]; then
    warn "Im Archiv nicht enthalten, uebersprungen: ${target}"
    continue
  fi

  # pmxcfs-Schutz: /etc/pve nur mit ausdruecklicher Erlaubnis
  if [[ "$target" == /etc/pve* && "$ALLOW_PVE" -eq 0 ]]; then
    warn "Verweigert: ${target} liegt unter /etc/pve (pmxcfs)."
    warn "  -> Nur mit --allow-pve, und nur wenn du die Folgen kennst."
    continue
  fi
  if [[ "$target" == /etc/pve* ]]; then
    warn "ACHTUNG: ${target} wird ins pmxcfs geschrieben. Im Cluster"
    warn "         synchronisiert sich /etc/pve sonst selbst. Letzte Chance."
  fi

  # Rueckfrage, falls nicht per -y unterdrueckt
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "    Wiederherstellen: ${target} ? [j/N] " answer
    case "$answer" in
      j|J|y|Y) ;;
      *) log "Uebersprungen: ${target}"; continue;;
    esac
  fi

  # Aktuellen Stand sichern, bevor wir ihn ueberbuegeln
  if [[ -e "$target" ]]; then
    backup_path="${target}.bak-${RESTORE_TS}"
    cp -a "$target" "$backup_path" \
      && log "Aktuellen Stand gesichert: ${backup_path}" \
      || warn "Konnte ${target} nicht sichern - fahre dennoch fort."
  fi

  # Zurueckspielen
  mkdir -p "$(dirname "$target")"
  if cp -a "$src" "$target"; then
    log "Wiederhergestellt: ${target}"
    applied=$((applied+1))
  else
    warn "Wiederherstellung fehlgeschlagen: ${target}"
  fi
done

log "${applied} Pfad(e) wiederhergestellt."
if [[ "$applied" -gt 0 ]]; then
  log "Nicht vergessen, betroffene Dienste neu zu starten, z.B.:"
  log "  systemctl restart networking      (nach Netzwerk-Restore)"
  log "  update-grub                       (nach GRUB-Restore)"
  log "  systemctl restart pve-cluster     (nach /etc/pve-Restore)"
fi
log "Fertig. Pruefe das Ergebnis, bevor du dem Host wieder vertraust."
exit 0
