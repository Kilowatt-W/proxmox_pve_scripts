#!/bin/bash
#
VERSION="20250314"
# USAGE Variable mittels Here-Document
USAGE=$(cat <<'EOF'
 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 Skript zur Replikation der ZFS-Datensätze einer VM von pve1 auf pve2.
 Neben der automatischen Moduswahl kann der Modus nun auch explizit via Parameter
 übergeben werden:
    zfs_repliacte.sh  <VMID> full  -> Erzwingt eine FULL-Replikation (z.B. wöchentlich per Cronjob,
                                      löscht Remote-Snapshots und aktualisiert die VM-Konfiguration).
    zfs_replicate.sh  <VMID> inc   -> Erzwingt eine inkrementelle Replikation (z.B. alle paar Stunden).
    zfs_replicate.sh  <VMID> del   -> Löscht alle lokalen QM-Snapshots mit dem Präfix "replicate-"
                                      ohne Übertragung.

 Voraussetzung: Snapshot-Namen müssen exakt dem Format entsprechen:
    replicate-YYYYMMDD-HHMMSS-full
    replicate-YYYYMMDD-HHMMSS-inc

 Manuell erstellte QM-Snapshots (ohne "replicate-") bleiben unberührt.

 Optionen :
   -h, --help      Zeigt diese Hilfe an.
   -v, --version   Zeigt die Versionsnummer an.
 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

EOF
)

set -e
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#set -x  # Debug: Aktiviere dies, falls du jeden Schritt sehen möchtest

# --- Parameterprüfung ---
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] ; then
    echo "Usage: $0 <VMID> [full|inc|del]"
    echo "$USAGE"
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "$USAGE"
    exit 0
fi

if [[ "$1" == "-v" || "$1" == "--version" ]]; then
    echo "$VERSION"
    exit 0
fi

VMID="$1"

# Optionaler zweiter Parameter: Replikationsmodus (full, inc oder del)
MODE="auto"
if [ "$#" -eq 2 ]; then
    if [ "$2" = "full" ] || [ "$2" = "inc" ] || [ "$2" = "del" ]; then
        MODE="$2"
    else
        echo "Usage: $0 <VMID> [full|inc|del]"
        exit 1
    fi
fi

# --- Grundeinstellungen ---
REMOTE="10.188.20.111"
RETENTION=5
VM_CONFIG_FILE="/etc/pve/qemu-server/${VMID}.conf"
LXC_CONFIG_FILE="/etc/pve/lxc/${VMID}.conf"
# ------- Ende Modiy -------


CONFIG_FILE=${VM_CONFIG_FILE}

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "${VMID} seems to be a LXC Container, switching Config Path"
    CONFIG_FILE=${LXC_CONFIG_FILE}
    if [ ! -f "${CONFIG_FILE}" ]; then
       echo "Error: Configuration file ${CONFIG_FILE} not found!"
       exit 1
    fi
fi

echo "=========================================="
echo "Starte Replikation für VMID: ${VMID}"
echo "Lokale Konfiguration: ${CONFIG_FILE}"
echo "Zielhost: ${REMOTE}"
echo "=========================================="

# --- DEL-Modus: Lösche ausschließlich QM-Snapshots ---
if [ "$MODE" = "del" ]; then
    echo "Modus 'del' gewählt: Lösche alle lokalen QM-Snapshots mit Präfix 'replicate-' für VMID ${VMID}."
    # Entferne führende Zeichen (z.B. Leerzeichen, Tabulatoren oder "`->")
    QM_SNAP_LIST=$(qm listsnapshot ${VMID} | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' || true)
    echo "Gefundene QM-Snapshots:"
    echo "$QM_SNAP_LIST"
    # Extrahiere nur die erste Spalte (den Snapshot-Namen) und lösche zeilenweise
    echo "$QM_SNAP_LIST" | awk '{print $1}' | while read snap; do
         echo "Lösche QM-Snapshot $snap..."
         qm delsnapshot ${VMID} "$snap"
    done
    echo "Alle lokalen QM-Snapshots wurden gelöscht."
    exit 0
fi

# --- Lokale QM-Snapshot-Liste einlesen (nur Snapshots mit "replicate-") ---
QM_SNAP_LIST=$(qm listsnapshot ${VMID} | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' || true)
echo "Lokale Replication-Snapshots (unsortiert):"
echo "$QM_SNAP_LIST"

# Sortiere die Liste (versionierte Sortierung)
SORTED_QM_SNAP_LIST=$(echo "$QM_SNAP_LIST" | sort -V)
echo "Sortierte lokale Replication-Snapshots:"
echo "$SORTED_QM_SNAP_LIST"

# --- Bestimme den gewünschten Snapshot-Typ ---
if [ "$MODE" = "auto" ]; then
    # Ermittele den maximalen Zeitstempel aus den FULL-Snapshots (inklusive Sekunden)
    LAST_FULL_TS=$(echo "$SORTED_QM_SNAP_LIST" | grep -E 'replicate-[0-9]{8}-[0-9]{6}-full' | cut -d'-' -f2-3 | sort -V | tail -n 1 || true)
    echo "Ermittelter letzter FULL-Zeitstempel: $LAST_FULL_TS"

    # Zähle inkrementelle Snapshots (Suffix "-inc") mit Zeitstempel größer als LAST_FULL_TS
    if [ -n "$LAST_FULL_TS" ]; then
        INC_TS=$(echo "$SORTED_QM_SNAP_LIST" | grep -E 'replicate-[0-9]{8}-[0-9]{6}-inc' || true | cut -d'-' -f2-3)
        if [ -z "$INC_TS" ]; then
            INC_COUNT=0
        else
            INC_COUNT=$(echo "$INC_TS" | awk -v last="$LAST_FULL_TS" 'BEGIN {count=0} { if ($0 > last) count++ } END { print count }')
        fi
    else
        INC_COUNT=0
    fi
    echo "Anzahl inkrementeller Snapshots nach dem letzten FULL: $INC_COUNT"

    if [ -n "$LAST_FULL_TS" ] && [ "$INC_COUNT" -lt "$RETENTION" ]; then
        echo "Weniger als $RETENTION inkrementelle Snapshots vorhanden. Neuer Snapshot wird inkrementell (inc)."
        NEW_TYPE="inc"
    else
        echo "Entweder kein FULL vorhanden oder $RETENTION oder mehr inkrementelle Snapshots existieren. Neuer Snapshot wird FULL."
        NEW_TYPE="full"
    fi
else
    # Modus wurde manuell festgelegt (full oder inc)
    NEW_TYPE="$MODE"
    echo "Modus wurde manuell festgelegt: Neuer Snapshot wird ${NEW_TYPE}."
fi

# --- Neuen Snapshot-Namen festlegen (inklusive Sekunden) ---
readonly NEW_SNAP="replicate-$(date +'%Y%m%d-%H%M%S')-${NEW_TYPE}"
echo "Neuer Snapshot-Name: $NEW_SNAP"

# --- Erstelle neuen VM-Snapshot mittels qm snapshot (falls noch nicht vorhanden) ---
if ! qm listsnapshot ${VMID} | sed 's/^[^A-Za-z0-9]*//' | awk '{print $1}' | grep -q "^${NEW_SNAP}$"; then
    echo "Erstelle neuen VM-Snapshot $NEW_SNAP..."
    qm snapshot ${VMID} "$NEW_SNAP" --description "Replikations-Snapshot, erstellt am $(date)"
else
    echo "Snapshot $NEW_SNAP existiert bereits."
fi

# Aktualisiere die QM-Snapshot-Liste nach dem Erstellen des neuen Snapshots,
# damit dieser in der späteren Kettenverwaltung berücksichtigt wird.
QM_SNAP_LIST=$(qm listsnapshot ${VMID} | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' | sort -V)
echo "Aktualisierte QM-Snapshot-Liste:"
echo "$QM_SNAP_LIST"

# --- ZFS-Replikation für jeden relevanten Disk-Eintrag ---
# Hier wird die Konfiguration so eingelesen, dass nur Zeilen bis zum ersten Auftreten
# eines "[" (also vor dem Snapshot-Block) verarbeitet werden.


# Lese alle Disk-Einträge (nur aus dem Hauptteil der Konfiguration, vor dem ersten "[") in ein Array
readarray -t disk_lines < <(sed '/^\[/q' "${CONFIG_FILE}" | grep -E '^[[:space:]]*(scsi|sata|virtio|efidisk)[0-9]+:')

# Debug: Zeige Anzahl gefundener Zeilen
echo "Gefundene Disk-Einträge: ${#disk_lines[@]}"

# Verarbeite alle Zeilen aus dem Array
for line in "${disk_lines[@]}"; do
    echo "var Line: $line"
    disk_dataset=$(echo "$line" | sed -E 's/^[a-z]+[0-9]+:\s*([^,]+).*/\1/')
    echo "var disk_dataset: $disk_dataset"
    if [ "$disk_dataset" = "none" ]; then
         echo "Überspringe ungültigen Disk-Eintrag: $line"
         continue
    fi
    if [[ "$disk_dataset" =~ ^local-zfs: ]]; then
         disk_dataset=$(echo "$disk_dataset" | sed 's/^local-zfs:/rpool\/data\//')
    fi
    disk_label=$(basename "$disk_dataset")
    echo "------------------------------------------"
    echo "Verarbeite Disk: ${disk_dataset} (Label: ${disk_label})"
    
    if [ "$NEW_TYPE" = "full" ]; then
         echo "Im FULL-Fall: Lösche auf dem Remote-Host alle Snapshots (Full & Inc) mit Präfix 'replicate-' für ${disk_dataset}..."
         ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do echo \"Lösche Remote-Snapshot \$snap\"; zfs destroy -R \"\$snap\"; done" || echo "Keine Remote-Snapshots zu löschen oder Fehler beim Löschen."
         SNAPNAME="${disk_label}_full_$(date +'%Y%m%d')"
         
         echo "Prüfe, ob lokaler ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert..."
         if ! zfs list -H -o name -t snapshot "${disk_dataset}@${NEW_SNAP}" > /dev/null 2>&1; then
              echo "Warnung: ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert nicht. (Disk: ${disk_label})"
              continue
         else
              echo "Lokaler ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert, verwende diesen."
         fi
         
         echo "Sende FULL-ZFS-Snapshot ${disk_dataset}@${NEW_SNAP}..."
         zfs send "${disk_dataset}@${NEW_SNAP}" | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
    else
         echo "Starte inkrementelle (differenzielle) ZFS-Replikation für ${disk_dataset}..."
         echo "Prüfe, ob lokaler ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert..."
         if ! zfs list -H -o name -t snapshot "${disk_dataset}@${NEW_SNAP}" > /dev/null 2>&1; then
              echo "Warnung: ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert nicht. (Disk: ${disk_label})"
              continue
         else
              echo "Lokaler ZFS-Snapshot ${disk_dataset}@${NEW_SNAP} existiert, verwende diesen."
         fi
         
         BASE_SNAP=$(zfs list -H -o name -t snapshot "${disk_dataset}" | grep '^'"${disk_dataset}@replicate-" | grep -v "@${NEW_SNAP}" | sort -V | tail -n 1 || true)
         if [ -z "$BASE_SNAP" ]; then
              echo "Kein Basis-Snapshot gefunden für inkrementelle Replikation bei ${disk_dataset}."
              echo "Behandle den Snapshot als FULL-Übertragung."
              ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do echo \"Lösche Remote-Snapshot \$snap\"; zfs destroy -R \"\$snap\"; done" || echo "Fehler beim Löschen der Remote-Snapshots (Fallback)."
              echo "Sende FULL-ZFS-Snapshot ${disk_dataset}@${NEW_SNAP}..."
              zfs send "${disk_dataset}@${NEW_SNAP}" | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
         else
              echo "Basis-Snapshot gefunden: $BASE_SNAP"
              if ! zfs send -i "$BASE_SNAP" "${disk_dataset}@${NEW_SNAP}" | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"; then
                   echo "Fehler: Inkrementelle Replikation für ${disk_dataset} fehlgeschlagen, versuche Fallback FULL..."
                   ssh root@"${REMOTE}" "for snap in \$(zfs list -H -o name -t snapshot | grep '^${disk_dataset}@replicate-'); do echo \"Lösche Remote-Snapshot \$snap\"; zfs destroy -R \"\$snap\"; done" || echo "Fehler beim Löschen der Remote-Snapshots (Fallback)."
                   echo "Sende FULL-ZFS-Snapshot ${disk_dataset}@${NEW_SNAP}..."
                   zfs send "${disk_dataset}@${NEW_SNAP}" | ssh root@"${REMOTE}" zfs receive -F "${disk_dataset}"
              fi
         fi
    fi

    echo "Lokale ZFS-Snapshot-Kette für ${disk_dataset} bleibt erhalten."
done



# --- Lokale QM-Snapshot-Kette verwalten (nur Snapshots mit "replicate-") ---
echo "Verwalte lokale QM-Snapshot-Kette (nur Snapshots mit 'replicate-')..."
QM_SNAP_LIST=$(qm listsnapshot ${VMID} | sed 's/^[^A-Za-z0-9]*//' | grep '^replicate-' | sort -V)
echo "Aktuelle lokale QM-Snapshots:"
echo "$QM_SNAP_LIST"

# Bestimme die Anzahl der QM-Snapshots (nur erste Spalte)
TOTAL_COUNT=$(echo "$QM_SNAP_LIST" | awk '{print $1}' | wc -l)
if [ "$NEW_TYPE" = "full" ] && [ "$TOTAL_COUNT" -gt 1 ]; then
    echo "Neuer Snapshot ist FULL. Lösche alle älteren FULL-Snapshots in der Kette..."
    echo "$QM_SNAP_LIST" | awk '{print $1}' | grep -v "^${NEW_SNAP}$" | while read snap; do
         echo "Lösche lokalen FULL QM-Snapshot $snap"
         qm delsnapshot ${VMID} "$snap"
    done
else
    echo "Lokale QM-Snapshot-Kette ist in Ordnung ($TOTAL_COUNT vorhanden)."
fi

if [ "$TOTAL_COUNT" -gt "$RETENTION" ]; then
    NUM_DELETE=$(( TOTAL_COUNT - RETENTION ))
    echo "Es gibt $TOTAL_COUNT lokale Replication-Snapshots. Lösche $NUM_DELETE der ältesten..."
    echo "$QM_SNAP_LIST" | awk '{print $1}' | head -n $NUM_DELETE | while read snap; do
         echo "Lösche lokalen QM-Snapshot $snap"
         qm delsnapshot ${VMID} "$snap"
    done
else
    echo "Lokale QM-Snapshot-Kette ist in Ordnung ($TOTAL_COUNT vorhanden)."
fi

# --- Remote-Konfiguration aktualisieren ---
echo "Bereinige und kopiere VM-Konfiguration nach ${REMOTE}..."
sed -e '/^\[/,$d' -e '/^parent:/d' -e '/^onboot:/ s/.*/onboot: 0/' -e '$a onboot: 0' "${CONFIG_FILE}" > /tmp/${VMID}.conf.modified
scp /tmp/${VMID}.conf.modified root@"${REMOTE}":/etc/pve/qemu-server/"${VMID}.conf"
rm -f /tmp/${VMID}.conf.modified

echo "=========================================="
echo "Replikation für VMID ${VMID} erfolgreich abgeschlossen."
exit 0
