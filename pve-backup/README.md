# PVE Host Config Tools

Zwei Bash-Scripts zum Sichern und kontrollierten Wiederherstellen der
Konfiguration eines Proxmox-VE-Hosts. Kein Hexenwerk, aber genau die
Nervenarbeit, die einem nach einer Neuinstallation sonst graue Haare wachsen
lässt: Netzwerk, Storage-Definitionen, VM-/CT-Configs, PCI-Passthrough-Gefrickel.

| Script | Aufgabe |
|--------|---------|
| `pve-config-backup.sh`  | Konfiguration in ein ZIP packen, optional per SSH wegschieben |
| `pve-config-restore.sh` | ZIP holen, prüfen, entpacken und *gezielt* zurückspielen |

## Was das hier ist – und was nicht

Diese Scripts sichern **Konfiguration**, kein vollwertiges Bare-Metal-Image.
Gäste-Disks (VMs/CTs) sind **nicht** enthalten – dafür gibt es Proxmox Backup
Server, `vzdump` oder ZFS `send`/`recv`. Wer ein bootfähiges Komplettabbild
will, greift zu Clonezilla. Diese Tools retten die Einstellungen, nicht die
Terabytes.

> **`/etc/pve` ist das pmxcfs-Cluster-Dateisystem.** Dateien daraus werden
> niemals blind auf einen frischen Host zurückgekippt. In einem Cluster
> synchronisiert sich `/etc/pve` beim Rejoin ohnehin selbst. Das Archiv ist
> als *Referenz* zum selektiven Kopieren gedacht – nicht als `unzip` mit
> Vollgas.

## Voraussetzungen

- Ein Proxmox-VE-Host (Debian-Basis), Ausführung als `root`
- `zip` für das Backup, `unzip` für den Restore
  - Falls nicht vorhanden: `apt-get install -y zip unzip`
- `sqlite3` (optional) für den SQL-Dump der pmxcfs-Datenbank
- SSH-Zugang zum Zielserver, falls Übertragung gewünscht

## Installation

```bash
git clone <repo-url>
cd <repo>
chmod +x pve-config-backup.sh pve-config-restore.sh
```

---

## `pve-config-backup.sh`

Sammelt die relevanten Konfigurationsdateien, packt sie in ein ZIP-Archiv,
erzeugt eine SHA-256-Prüfsumme und überträgt das Ganze optional per SSH.

### Sicherungsumfang

Neben dem offensichtlichen `/etc/pve` wird auch das gesichert, was bei reinem
`/etc/pve`-Kopieren gern vergessen wird: Netzwerk (`interfaces`),
Boot-/IOMMU-Konfiguration (`grub`, `kernel/cmdline`, `modules`, `modprobe.d`),
LVM, SSH-Host-Keys, APT-Repos, Cron sowie `passwd`/`shadow`/`group` plus
`subuid`/`subgid` (wichtig für unprivilegierte LXC). Zusätzlich landen die
pmxcfs-Datenbank (`config.db` als Rohdatei **und** SQL-Dump) sowie ein
`BACKUP-MANIFEST.txt` mit Systeminventar im Archiv. Nicht vorhandene Pfade
werden stillschweigend übersprungen.

### CLI-Parameter

| Option | Beschreibung | Default |
|--------|--------------|---------|
| `-o, --output DATEI`   | Voller Pfad/Name der ZIP-Datei | `<tmpdir>/<prefix>-<host>-<timestamp>.zip` |
| `-p, --prefix NAME`    | Dateinamen-Präfix | `pve-config` |
| `-t, --tmpdir VERZ`    | Arbeits-/Ablageverzeichnis | `/tmp` |
| `-d, --dest ZIEL`      | SSH-Ziel `user@host:/pfad/` | – (ohne Angabe nur lokal) |
| `-P, --port PORT`      | SSH-Port | `22` |
| `-i, --identity DATEI` | SSH-Private-Key | – |
| `-r, --rsync`          | `rsync` statt `scp` verwenden | aus |
| `-e, --extra PFAD`     | Zusätzlicher Pfad (mehrfach nutzbar) | – |
| `-k, --keep-local`     | Lokale ZIP nach Transfer behalten | aus |
| `-n, --no-transfer`    | Nur lokal sichern | aus |
| `-q, --quiet`          | Nur Warnungen/Fehler ausgeben | aus |
| `-h, --help`           | Hilfe anzeigen | – |

### Beispiele

```bash
# 1) Nur lokales Backup nach /tmp (Standard-Dateiname)
./pve-config-backup.sh -n

# 2) Backup erstellen und per scp auf den Backup-Host schieben
./pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/

# 3) Eigener Key, Port 2222, rsync, zwei zusätzliche Pfade
./pve-config-backup.sh -d root@10.0.0.9:/backups/ -P 2222 -i ~/.ssh/backup \
                       -r -e /etc/iscsi -e /root/scripts

# 4) Fester Dateiname und eigenes Ablageverzeichnis
./pve-config-backup.sh -o /mnt/nas/pve01-config.zip -n

# 5) Lokale Kopie nach dem Transfer behalten
./pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/ -k
```

### Automatisierung (Cron)

Tägliches Backup um 02:15 Uhr, ältere Archive auf dem Zielhost aufräumt man
besser dort separat:

```cron
15 2 * * * root /opt/pve-tools/pve-config-backup.sh -d backup@nas.local:/srv/pve-backups/ -q
```

---

## `pve-config-restore.sh`

Holt ein Archiv (lokal oder per SSH), verifiziert die Prüfsumme, entpackt es
und stellt – **nur auf ausdrückliche Anweisung** – einzelne Pfade wieder her.

> **Der Default-Modus restauriert nichts.** Er entpackt und zeigt nur an. Das
> ist Absicht: Ein Restore-Script, das ungefragt `/etc` überschreibt, ist kein
> Werkzeug, sondern eine Falle. Erst mit `--apply` wird tatsächlich etwas
> zurückgespielt – und auch dann wird der bestehende Stand vorher nach
> `<ziel>.bak-<timestamp>` gesichert.

### CLI-Parameter

| Option | Beschreibung | Default |
|--------|--------------|---------|
| `-i, --input DATEI`    | Lokales ZIP-Archiv | – |
| `-f, --from SSH-QUELLE`| Archiv per SSH holen, `user@host:/pfad/x.zip` | – |
| `-P, --port PORT`      | SSH-Port für `--from` | `22` |
| `-I, --identity DATEI` | SSH-Private-Key für `--from` | – |
| `-t, --tmpdir VERZ`    | Arbeitsverzeichnis | `/tmp` |
| `-l, --list`           | Archivinhalt auflisten und beenden | aus |
| `-D, --diff`           | Archiv gegen das laufende System diffen | aus |
| `-a, --apply PFAD`     | Diesen Pfad wiederherstellen (mehrfach nutzbar) | – |
| `--allow-pve`          | `--apply` auch für Pfade unter `/etc/pve` erlauben | aus |
| `--no-checksum`        | Prüfsummen-Check überspringen (nicht empfohlen) | aus |
| `-y, --yes`            | Rückfragen vor dem Wiederherstellen unterdrücken | aus |
| `-q, --quiet`          | Nur Warnungen/Fehler ausgeben | aus |
| `-h, --help`           | Hilfe anzeigen | – |

Quelle ist **genau eine** von `--input` oder `--from`.

### Beispiele

```bash
# 1) Archiv nur entpacken und anschauen (verändert nichts)
./pve-config-restore.sh -i /tmp/pve-config-pve01-20260518-021500.zip

# 2) Archivinhalt auflisten
./pve-config-restore.sh -i ./pve-config-pve01.zip -l

# 3) Archiv vom Backup-Host holen und gegen das System diffen
./pve-config-restore.sh -f backup@nas.local:/srv/pve-backups/pve-config-pve01.zip -D

# 4) Netzwerk- und GRUB-Konfiguration gezielt zurückspielen (ohne Rückfrage)
./pve-config-restore.sh -i ./pve-config-pve01.zip \
                        -a /etc/network/interfaces -a /etc/default/grub -y

# 5) Einen /etc/pve-Pfad zurückspielen – nur wenn du WIRKLICH weisst, was du tust
./pve-config-restore.sh -i ./pve-config-pve01.zip \
                        -a /etc/pve/storage.cfg --allow-pve
```

### Nach dem Restore

Betroffene Dienste neu starten – das Script erinnert daran, je nach
zurückgespieltem Pfad:

```bash
systemctl restart networking      # nach Netzwerk-Restore
update-grub                       # nach GRUB-Restore
systemctl restart pve-cluster     # nach /etc/pve-Restore
```

---

## Typischer Workflow

```text
  Quell-Host                          Backup-Server                Ziel-Host
 ┌────────────┐   pve-config-backup   ┌──────────────┐   restore   ┌──────────┐
 │ /etc/pve   │ ───────scp/rsync────► │  *.zip        │ ──────────► │ frisches │
 │ /etc/...   │      + .sha256        │  *.zip.sha256 │   -i / -f   │ PVE      │
 └────────────┘                       └──────────────┘             └──────────┘
                                                              dann gezielt -a
```

1. Auf dem Quell-Host: `pve-config-backup.sh -d backup@host:/pfad/`
2. Im Ernstfall auf dem neuen Host: `pve-config-restore.sh -f backup@host:/pfad/x.zip -D`
   (erst diffen, schauen, *dann* mit `-a` selektiv zurückspielen)

## Restore-Strategie – kurz und schmerzlos

- **Erst `--diff`, dann `--apply`.** Sehen, was abweicht, bevor man etwas anfasst.
- **NIC-Namen prüfen.** Neue Hardware = neue Interface-Namen. `/etc/network/interfaces`
  aus dem Archiv passt dann eventuell nicht 1:1.
- **`/etc/pve` ist Sonderzone.** Im Cluster regelt sich das beim Rejoin selbst;
  einzelne Dateien nur mit `--allow-pve` und wachem Verstand.
- **Das beste Backup ist ein getestetes.** Restore einmal auf einem Wegwerf-Host
  durchspielen, bevor der Ernstfall es tut.

## Lizenz

Nach Belieben anpassen – z.B. MIT.
