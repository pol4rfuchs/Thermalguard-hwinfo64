# HWiNFO Thermal Guard v1.51

**[Deutsch](README.md)** | [English](README.en.md)

Automatischer thermischer Schutz für Windows-Gaming-PCs.  
Überwacht CPU- und GPU-Sensoren in Echtzeit via HWiNFO + RemoteHWInfo und reagiert bei kritischen Temperaturen in drei Eskalationsstufen: **Warnung → Programme beenden → Notabschaltung.**

**Hardware-Support:** 🟢 volle Unterstützung · 🟠 Basis-Monitoring · 🔴 noch nicht unterstützt

[![AMD CPU](https://img.shields.io/badge/AMD_CPU-volle_Unterst%C3%BCtzung-brightgreen?logo=amd&logoColor=white)](#gpu-profil)
[![NVIDIA GPU](https://img.shields.io/badge/NVIDIA_GPU-volle_Unterst%C3%BCtzung-brightgreen?logo=nvidia&logoColor=white)](#gpu-profil)
[![AMD GPU](https://img.shields.io/badge/AMD_GPU-volle_Unterst%C3%BCtzung-brightgreen?logo=amd&logoColor=white)](#gpu-profil)
[![Intel CPU](https://img.shields.io/badge/Intel_CPU-nicht_unterst%C3%BCtzt-red?logo=intel&logoColor=white)](#sensordaten-beisteuern)
[![Intel Arc GPU](https://img.shields.io/badge/Intel_Arc_GPU-nicht_unterst%C3%BCtzt-red?logo=intel&logoColor=white)](#sensordaten-beisteuern)

**Details nach Generation/Sockel:**

| Architektur | Generation | Status |
| --- | --- | --- |
| AMD CPU (AM4) | Ryzen 1000–5000 (Zen–Zen 3) | ✅ Getestet (5800X3D) |
| AMD CPU (AM5) | Ryzen 7000–9000 (Zen 4/5) | ⚠️ Gleiches Sensor-Label (`Tctl/Tdie`), sollte laufen, aber ungetestet |
| NVIDIA GPU | RTX 50 (Blackwell) | ✅ Voll getestet (5070 Ti), inkl. Memory-Junction-Temp + Performance-Limit-Flags |
| NVIDIA GPU | RTX 20/30/40 (Turing–Ada) | ⚠️ Basis-Temp sollte laufen, Memory-Junction-Temp wird von NVIDIA-Treibern auf älteren Karten teils gar nicht gemeldet |
| AMD GPU | RX 9000 (RDNA4) | ✅ Basis-Monitoring getestet (9070 XT); Memory-Junction-Temp + Power laufen über dasselbe AMD-Profil, aber nicht separat auf RDNA4 bestätigt |
| AMD GPU | RX 6000/7000 (RDNA2/3) | ✅ Voll getestet (6800 XT), inkl. Memory-Junction-Temp + Power (TGP) |
| Intel CPU | alle | ❌ Nicht unterstützt (kein Tctl/Tdie-Äquivalent, andere Sensor-Namen) |
| Intel Arc GPU | A-/B-Serie | ❌ Nicht unterstützt |

> AMD GPU: volle Sensor-Abdeckung (Temp/Hotspot/Fan/Load/Memory-Junction-Temp/
> Power-Draw) bestätigt auf einer RX 6800 XT via Sensor-Dump. Einzige
> verbleibende Lücke gegenüber NVIDIA: die Performance-Limit-Flags, die
> HWiNFO nur für NVIDIA-GPUs als eigene Yes/No-Sensoren exponiert.

<!-- -->

> **Randnotiz:** Angesichts der aktuellen DRAM-Krise und der entsprechenden
> Mondpreise lohnt sich ein noch genauerer Blick auf die eigene Hardware —
> ThermalGuard hilft zumindest dabei, dass RAM/GPU/CPU nicht durch Überhitzung
> vorzeitig den Geist aufgeben, wenn Ersatz gerade richtig teuer ist.

---

## Schnellstart (frischer PC, nix installiert)

1. Ordner `C:\Tools\HWiNFO-ThermalGuard\` anlegen
2. Alle Dateien reinkopieren:
   - `HWiNFO-ThermalGuard.ps1`
   - `Start-HWiNFO-Remote.bat`
   - `Start-HWiNFO-Remote.vbs`
   - `Install-ScheduledTask.ps1` (richtet den Autostart ein)
   - `Approve-ThermalGuardUpdate.ps1` (nur nötig, wenn du den Update-Download nutzt)
   - `Get-SensorDump.ps1` (optional, nur zum [Sensordaten beisteuern](#sensordaten-beisteuern))
3. `HWiNFO-ThermalGuard.ps1` öffnen → die ersten Zeilen anpassen:

   ```powershell
   $GPUProfile = "AUTO"      # erkennt GPU automatisch (oder "NVIDIA" / "AMD")
   $EnableNtfy = $false      # kein ntfy-Server? → false
   ```

4. Autostart einrichten: `Install-ScheduledTask.ps1` in einer **Administrator-PowerShell** ausführen (siehe [Autostart](#autostart-einrichten)).
   Zum schnellen Testen reicht auch: `Start-HWiNFO-Remote.bat` per Rechtsklick → **Als Administrator ausführen**
5. Fertig — alles was fehlt (HWiNFO64, RemoteHWInfo, BurntToast) wird automatisch installiert

---

## Was wird automatisch installiert?

| Dependency | Methode | Ziel |
| --- | --- | --- |
| **HWiNFO64** | `winget install` (silent) | Standard-Installationspfad |
| **RemoteHWInfo** | GitHub ZIP-Download + Entpacken | `C:\Tools\RemoteHWInfo\` |
| **BurntToast** | `Install-Module` (PowerShell) | PS-Modulpfad |

Die automatische Installation greift **nur** wenn die Software nicht gefunden wird. Ist sie bereits installiert (egal wo), wird der vorhandene Pfad verwendet.

Falls winget bei HWiNFO fehlschlägt (z.B. Windows Update Service deaktiviert), erscheint im Log ein Download-Link für die manuelle Installation.

---

## Dateistruktur

```text
C:\Tools\HWiNFO-ThermalGuard\
├── HWiNFO-ThermalGuard.ps1          ← Hauptscript
├── Start-HWiNFO-Remote.bat          ← Launcher (Schnellcheck, PowerShell-Erkennung)
├── Start-HWiNFO-Remote.vbs          ← Unsichtbar-Wrapper
├── Install-ScheduledTask.ps1        ← richtet den Autostart-Task ein (einmalig, als Admin)
├── Approve-ThermalGuardUpdate.ps1   ← installiert ein bereitgestelltes Update (Update-Download)
├── Get-SensorDump.ps1               ← optional: Sensordaten für ein GitHub-Issue sammeln
└── README.md                        ← Diese Dokumentation
```

Beim Update-Download kommen automatisch dazu (neben dem Hauptscript):

```text
HWiNFO-ThermalGuard.pending-vX.Y.ps1          ← bereitgestelltes, noch nicht aktives Update
HWiNFO-ThermalGuard.pending-vX.Y.ps1.sha256   ← der beim Download geprüfte Hash
HWiNFO-ThermalGuard.backup-vX.Y.ps1           ← Sicherung der Version X.Y (der Datei, die sie enthält)
HWiNFO-ThermalGuard.failed-vX.Y.txt           ← Version X.Y hat den Health-Check nicht bestanden (Rollback)
```

---

## Setup im Detail

### GPU-Profil

```powershell
$GPUProfile = "AUTO"      # Erkennt automatisch NVIDIA oder AMD (Standard)
$GPUProfile = "NVIDIA"    # Manueller Override: RTX 5070 Ti, RTX 4090, etc.
$GPUProfile = "AMD"       # Manueller Override: RX 9070 XT, RX 6800 XT, etc.
```

Bei `AUTO` erkennt das Script die GPU automatisch über zwei Methoden:

1. **Windows WMI** (`Win32_VideoController`) — funktioniert immer, auch ohne HWiNFO
2. **HWiNFO JSON** (Fallback) — liest den GPU-Namen aus den Sensor-Daten

Die Profile setzen automatisch die richtigen Sensor-Labels:

| | NVIDIA | AMD |
| --- | --- | --- |
| GPU Temp | `GPU Temperature` | `GPU Temperature` |
| GPU Hotspot | Nicht verfügbar | `GPU Hot Spot Temperature` |
| GPU Fan | `GPU Fan1` | `GPU Fan` |
| GPU Load | `GPU Core Load` | `GPU Utilization` |
| GPU Memory Junction | `GPU Memory Junction Temperature` | `GPU Memory Junction Temperature` |
| GPU Power | `GPU Power` | `Total Graphics Power (TGP)` |

### Toggles

```powershell
$EnableCPU   = $true     # CPU-Temperatur überwachen
$EnableGPU   = $true     # GPU-Temperatur überwachen
$EnableNtfy  = $true     # Push-Benachrichtigungen via ntfy
$EnableFipha = $false    # fipha mitstarten und überwachen (optional, siehe unten)
```

**fipha** ([mhwlng/fipha](https://github.com/mhwlng/fipha)) veröffentlicht HWiNFO-Sensoren per MQTT-Discovery in Home Assistant. Das ist ein Extra und gehört nicht zum Hitzeschutz: ThermalGuard startet und überwacht den Prozess nur mit, wenn du `$EnableFipha = $true` setzt. fipha braucht seine eigene `mqtt.config` neben der `fipha.exe`. Der Pfad wird wie bei den anderen Programmen gesucht (`$Fipha_Path`, sonst `C:\Tools\fipha\` und `C:\Tools\`). Fehlt fipha oder stürzt es ab, ist das nie ein Grund für Stufe 2/3.

### ntfy einrichten

**Eigener Server:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.deine-domain.example"
$NTFY_TOPIC = "ha-system"
```

**Kein eigener Server? Kostenlos über ntfy.sh:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-deinname"    # beliebiger Name, muss nur einzigartig sein
```

Dann die ntfy-App installieren (Android/iOS), Topic subscriben, fertig.

**Server mit Zugriffsschutz (Auth):**

```powershell
$NTFY_Token    = "tk_..."     # Access-Token, wird als "Authorization: Bearer" gesendet (bevorzugt)
# oder statt Token:
$NTFY_User     = "name"       # HTTP Basic
$NTFY_Password = "passwort"
```

Token hat Vorrang, wenn beides gesetzt ist. Beides leer = offenes Topic. Die Zugangsdaten stehen im Klartext im Script, also lieber ein Token, das nur auf dieses Topic schreiben darf, als dein Haupt-Passwort.

**Kein ntfy gewünscht:**

```powershell
$EnableNtfy = $false
```

Windows Toast-Benachrichtigungen laufen immer, unabhängig von ntfy.

### Update-Check und Update-Installation (optional)

Standardmäßig **alles aus**. Drei Stufen, jede einzeln zuschaltbar:

```powershell
$EnableUpdateCheck        = $true     # 1) melden: Toast + ntfy, wenn ein neueres Release existiert
$UpdateCheckRepo          = "pol4rfuchs/ThermalGuard-hwinfo64"   # "owner/repo"
$UpdateCheckIntervalHours = 24

$EnableAutoDownload       = $true     # 2) laden, prüfen, bereitstellen - aber NICHT aktivieren
$EnableAutoInstall        = $false    # 3) bereitgestelltes Update automatisch einspielen (nicht empfohlen)

$UpdateRequireHash        = $true     # SHA-256 aus dem Release ist Pflicht (Standard)
$UpdateBackupsToKeep      = 3         # Sicherungen der alten Versionen (mindestens 1 bleibt)
$UpdateHealthCheckTimeoutSec = 90     # so lange wartet der Installer auf die neue Version
```

**1) Check** (`$EnableUpdateCheck`)

- Läuft einmal beim Start und danach alle `$UpdateCheckIntervalHours` Stunden weiter (geprüft aus dem Watchdog-Takt heraus, damit auch lange Sessions über den 12h-Reset hinweg mitbekommen, wenn zwischenzeitlich was released wurde).
- Meldet eine neue Version **einmal**, nicht bei jedem Check erneut, solange nicht upgedatet wird.
- Netzwerkfehler (z.B. offline) landen nur im Log, es gibt keinen Alert-Spam.
- Nutzt für die Meldung dieselbe Toast+ntfy-Infrastruktur wie die Temperatur-Alerts, der Toast kommt auch mit `$EnableNtfy = $false`.

**2) Download und Bereitstellen** (`$EnableAutoDownload`)

1. Lädt `HWiNFO-ThermalGuard.ps1` aus dem Release (Fallback: die Rohdatei am Tag).
2. **Prüft den SHA-256** gegen den Hash, der mit dem Release veröffentlicht wurde: ein Asset `HWiNFO-ThermalGuard.ps1.sha256` (Inhalt: der Hash, optional mit Dateiname) oder ein Asset `SHA256SUMS` im üblichen Format `<hash>  <datei>`.
3. Prüft die **Syntax** (Parser, ohne Ausführen).
4. Sichert die laufende Datei als `HWiNFO-ThermalGuard.backup-vX.Y.ps1`, wobei `X.Y` die Version ist, die die Datei **enthält**.
5. Stellt das Update als `HWiNFO-ThermalGuard.pending-vX.Y.ps1` bereit (mit `.sha256`-Datei daneben) und meldet das per Toast + ntfy.

Ein fehlgeschlagener Download wird beim nächsten Check erneut versucht. Eine Version, die abgelehnt wurde (Hash passt nicht, Syntaxfehler, kein Hash), wird innerhalb eines Laufs nicht in jedem Intervall erneut geladen (nach einem Neustart des Guards wird sie noch einmal bewertet).

**3) Installieren**

*Manuell (empfohlen):* in einer **Administrator-PowerShell** im Script-Ordner

```powershell
powershell -ExecutionPolicy Bypass -File .\Approve-ThermalGuardUpdate.ps1
```

Das Script zeigt Version, SHA-256, Hash- und Syntax-Check des bereitgestellten Updates und fragt nach (`-Yes` überspringt die Frage, `-ListOnly` zeigt nur an). Dann läuft der Installer des laufenden Scripts:

```text
Hash des bereitgestellten Files erneut prüfen → Syntax erneut prüfen
  → frische Sicherung der laufenden Datei (backup-v<laufende Version>)
  → Task deaktivieren, alte Instanz stoppen
  → Austausch
  → Task aktivieren, neue Version starten
  → bis zu 90 s auf den Health-Marker im Log warten
        ├── gefunden:  Meldung "ThermalGuard updated"
        └── nicht gefunden: ROLLBACK (Sicherung zurück, neu starten, Meldung "rolling back",
                            Datei failed-vX.Y.txt, damit dieselbe Version nicht in einer Schleife neu installiert wird)
```

Der **Health-Marker** ist die Logzeile `=== HEALTHY: first successful sensor poll (...) ===`. Die schreibt die neue Version erst nach dem ersten Poll, in dem **alle** primären Temperatursensoren (CPU und GPU, soweit aktiviert) einen gültigen Wert liefern, der Guard also nicht blind ist. "Software Check complete" reicht bewusst nicht: die Zeile steht auch im Fehlerfall im Log.

*Automatisch* (`$EnableAutoInstall = $true`, braucht `$EnableAutoDownload = $true`): derselbe Installer, ohne dass du bestätigst. **Für ein Script, das bei Überhitzung den PC herunterfährt, nicht empfohlen.**

Läuft das Setup über `shell:startup` statt über den Task, startet der Installer die neue Version über `Start-HWiNFO-Remote.vbs`.

#### Update-Sicherheit

- **Nie bei Hitze:** Ein Update wird weder geprüft noch bereitgestellt noch installiert, solange ein Sensor im Stufe-2/3-Timer ist oder der [Daten-Failsafe](#failsafe-bei-datenverlust) zählt. Überhitzungsschutz geht immer vor.
- **Der Hash ist kein Vertrauensanker.** Er kommt aus demselben Release wie die Datei. Er schützt vor einem kaputten oder auf dem Weg manipulierten Download, **nicht** vor einem kompromittierten Repo oder Maintainer-Konto. Wer das Repo nicht selbst kontrolliert, lässt `$EnableAutoInstall` aus und schaut sich die Datei vor `Approve` an.
- **Ohne Hash:** Mit `$UpdateRequireHash = $true` (Standard) wird nichts bereitgestellt. Mit `$false` wird das Update als **UNVERIFIED** bereitgestellt und **nie automatisch** installiert, auch nicht mit `$EnableAutoInstall = $true`. Der Installer verlangt dann außerdem `$UpdateRequireHash = $false`, wenn keine `.sha256`-Datei neben dem bereitgestellten File liegt.
- **Manipulation nach dem Download:** Der Installer prüft das bereitgestellte File direkt vor dem Austausch noch einmal gegen die gespeicherte `.sha256`-Datei.
- **Rollback-Quelle ist immer die Datei, die unmittelbar vor dem Austausch lief**, auch beim zweiten, dritten Update.
- **Erste Runde:** Der Installer läuft aus der *alten* Datei. Verbesserungen am Installer selbst greifen deshalb erst beim Update *von* der neuen Version weg. Den Schritt auf v1.51 machst du von Hand (Datei ersetzen).
- Zwischen "alte Instanz gestoppt" und "erster Poll der neuen" (normalerweise deutlich unter einer Minute) überwacht niemand die Temperaturen: nicht bei heißem oder ausgelastetem PC installieren.

### Schwellwerte

Zwei Wege, CPU/GPU Warn+Crit zu setzen:

**A) Empfohlen — den einen Datenblatt-Wert eintragen, Rest automatisch:**

```powershell
$CPU_Tjmax       = 90     # z.B. 90 für einen Ryzen 7 5800X3D - Datenblatt der CPU
$GPU_MaxTempSpec = 88     # offizielle Max-GPU-Temp lt. Hersteller-Spec-Seite
```

Daraus errechnet sich automatisch:

```powershell
$CPU_WarnMarginC = 10   # Warn = Tjmax - 10
$CPU_CritMarginC = 3    # Crit = Tjmax - 3
$GPU_WarnMarginC = 8    # Warn = MaxTempSpec - 8
$GPU_CritMarginC = 2    # Crit = MaxTempSpec - 2
```

Kein Raten mehr nötig, welche Warn/Crit-Zahl aus einer generischen Tabelle "passt" — nur der eine offizielle Rohwert wird gebraucht, den Marge übernimmt das Script.

**B) Manuell, volle Kontrolle:**

`$CPU_Tjmax` und `$GPU_MaxTempSpec` auf `$null` lassen (Standard) und stattdessen direkt setzen:

```powershell
$CPU_WarnTemp    = 80     # CPU Vorwarnung ab hier
$CPU_CritTemp    = 87     # CPU Hard-Stop ab hier
$GPU_WarnTemp    = 80     # GPU Vorwarnung
$GPU_CritTemp    = 86     # GPU Hard-Stop
```

Das sind auch genau die Fallback-Werte, die gelten, solange `$CPU_Tjmax`/`$GPU_MaxTempSpec` `$null` sind — bestehende Configs von vor diesem Feature ändern sich also nicht.

Unverändert, unabhängig von A/B:

```powershell
$GPU_HotspotWarn = 95     # GPU Hotspot Vorwarnung (nur AMD)
$GPU_HotspotCrit = 100    # GPU Hotspot Hard-Stop (nur AMD)
$GPU_FanWarnRPM  = 300    # Fan-Warnung unter diesem Wert bei Last
$GPU_FanCritRPM  = 0      # Fan Hard-Stop: 0 RPM bei Last
```

> **Wichtig:** Auch mit Weg A ersetzt das Script keine eigene Recherche —
> `$CPU_Tjmax` (Datenblatt der CPU) und `$GPU_MaxTempSpec` (Hersteller-Spec-
> Seite der Grafikkarte) musst du selbst nachschlagen, die kennt HWiNFO
> nicht zuverlässig als Sensorwert. Zum Vergleich: die tatsächliche
> Konfiguration in diesem Repo ist auf einen Ryzen 7 5800X3D (Tjmax 90°C)
> und eine RTX 5070 Ti (offizielles Maximum 88°C) abgestimmt — genau die
> Zahlen, die oben als Beispiel für `$CPU_Tjmax`/`$GPU_MaxTempSpec` stehen.

### Timing

```powershell
$PollInterval = 5     # Sekunden zwischen Abfragen
$Stage2Delay  = 30    # Sekunden bis Programme beendet werden
$Stage3Delay  = 90    # Sekunden bis Shutdown (gesamt ab Trigger)
```

### Failsafe bei Datenverlust

Ohne Sensordaten ist ThermalGuard blind. Früher gab es dann nur Alarme, während die Stufe-2/3-Timer (die einen Messwert brauchen) einfroren: Fällt HWiNFO mitten in der Hitze aus, passierte nichts mehr. Jetzt zählt auch das Blindsein:

```powershell
$EnableDataLossFailsafe = $true
$DataLossStage2Sec      = 180   # nach 3 min blind: Prozessliste beenden (wie Stufe 2)
$DataLossShutdownSec    = 420   # nach 7 min blind: Notabschaltung (wie Stufe 3)
```

- **Blind** heißt: kein gültiger Wert für `CPU Tctl/Tdie` (wenn `$EnableCPU`) bzw. `GPU Temperature` (wenn `$EnableGPU`). Also: Endpoint nicht erreichbar, HWiNFO tot, Label nicht gefunden, Einheit ist keine Temperatur, Wert außerhalb -20..150 °C.
- Der Zähler startet beim ersten blinden Poll und wird zurückgesetzt, sobald wieder gültige Werte kommen. Normale Watchdog-Neustarts (HWiNFO ca. 25 s, 12h-Reset ca. 30 s) liegen weit unter den 180 s.
- Solange der Zähler läuft, gibt es keinen Update-Check, und der 12h-Reset wird aufgeschoben.
- Die normalen Alarme ("data source offline", "Sensor missing") kommen weiterhin lange vorher.
- **Nach einem Hardwaretausch:** Sensor-Labels im Self-Test-Log prüfen (siehe [Sensor-Labels prüfen](#sensor-labels-prüfen-bei-problemen)). Passt das Label nicht, wäre der Guard blind und der Failsafe fährt nach 7 Minuten herunter. Während eines Tauschs wie bisher `$EnableGPU = $false` setzen.
- Abschalten: `$EnableDataLossFailsafe = $false` (altes Verhalten: nur Alarm).

### Prozessliste (Stufe 2)

```powershell
$KillProcesses = @(
    "TslGame"                  # PUBG
    "Stalker2-Win64-Shipping"  # Stalker 2
    "obs64"                    # OBS Studio
    "chrome"
    "firefox"
    "floorp"
)
```

Prozessnamen findest du im Task-Manager unter "Details" oder via:

```powershell
Get-Process | Where-Object { $_.MainWindowTitle -ne "" }
```

### Pfade (optional)

Normalerweise nicht nötig — das Script scannt automatisch. Nur setzen wenn die Software an einem ungewöhnlichen Ort liegt:

```powershell
$HWiNFO_Path       = ""    # leer = auto-scan
$RemoteHWInfo_Path  = ""    # leer = auto-scan
```

---

## Autostart einrichten

### Methode 1: Geplanter Task (empfohlen)

1. Alle Dateien in einen Ordner (z.B. `C:\Tools\HWiNFO-ThermalGuard\`)
2. In einer **Administrator-PowerShell** einmalig ausführen:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-ScheduledTask.ps1
   ```

Das legt den Task `HWiNFO Thermal Guard` an. Er startet beim Anmelden **mit höchsten Rechten, ohne UAC-Abfrage**, und wiederholt sich alle 5 Minuten (**Selbstheilung**): Läuft der Guard, beendet sich der Launcher lautlos. Ist der Guard abgestürzt, startet er ihn neu. Früher blieb ein abgestürzter Guard bis zur nächsten Anmeldung tot.

- Anderes Intervall: `-RepeatMinutes 10`. Ohne Wiederholung (nur Start bei Anmeldung): `-RepeatMinutes 0`.
- Das Script liest am Ende aus, was Windows tatsächlich gespeichert hat, und warnt, wenn keine Wiederholung aktiv ist.
- Sofort testen: `Start-ScheduledTask -TaskName 'HWiNFO Thermal Guard'`
- **Nicht zusätzlich** die `.vbs` in `shell:startup` legen, sonst startet die Kette doppelt.

### Methode 2: shell:startup (ohne Selbstheilung)

1. `.bat` und `.vbs` im **gleichen Ordner**
2. `Win+R` → `shell:startup` → Enter
3. Rechtsklick auf `.vbs` → **Verknüpfung erstellen** → Verknüpfung in den startup-Ordner verschieben

Nachteile: kein UAC-freier Start mit Administratorrechten (das Script braucht sie für `shutdown.exe` und zum Beenden von Prozessen) und keine Wiederholung nach einem Absturz. Nur sinnvoll, wenn dein Konto ohnehin ohne UAC-Abfrage mit Adminrechten startet.

### Was beim Start passiert

```text
Task (Anmeldung + alle 5 Min)   oder   Start-HWiNFO-Remote.vbs (unsichtbar)
    └── Start-HWiNFO-Remote.bat
            ├── Schnellcheck: ThermalGuard läuft schon? → lautlos beenden
            ├── PowerShell 7 oder 5.1 erkennen
            ├── Bekannte Script-Dateien entsperren (Mark-of-the-Web)
            └── HWiNFO-ThermalGuard.ps1 starten (versteckt)
                    ├── Shared Memory per Registry aktivieren
                    ├── Pfade scannen, fehlende Software downloaden
                    ├── HWiNFO64, RemoteHWInfo (und fipha) starten, falls sie nicht laufen
                    └── ab hier: Überwachung + Watchdog
```

Die `.bat` startet und prüft **nicht** selbst HWiNFO64, RemoteHWInfo oder fipha: das macht ausschließlich `HWiNFO-ThermalGuard.ps1`. Die `.bat` kann beliebig oft ausgeführt werden. Läuft der Guard schon, passiert nichts. Der Duplikat-Check ignoriert Installer- und Dry-Run-Instanzen (`-InstallPendingUpdate`, `-DryRun`, `-SimulateTemp`). Der Log der **letzten echten Startsequenz** steht in `%USERPROFILE%\HWiNFO-ThermalGuard\autostart.log`; die lautlosen Wiederholungen überschreiben ihn nicht.

---

## Pfad-Scan Reihenfolge

Gescannt wird nur eine feste Liste von Ordnern (jeweils inklusive Unterordnern bis Tiefe 3, es gewinnt die größte passende Datei). Desktop und Downloads werden **bewusst nicht** durchsucht (Sicherheit): liegt deine Installation dort, setze den `*_Path`-Override oder verschiebe sie nach `C:\Tools\`.

### HWiNFO64

1. Manueller Override (`$HWiNFO_Path`)
2. `C:\Program Files\HWiNFO64\`
3. `C:\Program Files (x86)\HWiNFO64\`
4. `C:\Tools\HWiNFO64\`
5. `C:\Tools\` (inkl. Unterordner)
6. System-PATH
7. Auto-Install via `winget install REALiX.HWiNFO`

### RemoteHWInfo

1. Manueller Override (`$RemoteHWInfo_Path`)
2. `C:\Tools\RemoteHWInfo\`
3. `C:\Tools\` (inkl. Unterordner, findet z.B. `C:\Tools\RemoteHWInfo_v0.5\`)
4. System-PATH
5. Auto-Download von GitHub → `C:\Tools\RemoteHWInfo\` (der SHA-256 des Downloads wird nur geloggt, nicht gegen einen festen Wert geprüft: gegen die Release-Seite abgleichen)

### fipha (nur mit `$EnableFipha = $true`)

1. Manueller Override (`$Fipha_Path`)
2. `C:\Tools\fipha\`
3. `C:\Tools\` (inkl. Unterordner)

Wird fipha nicht gefunden, gibt es nur eine Warnung im Log.

---

## 3-Stufen-Eskalation

```text
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  t=0s     Kritische Schwelle erreicht                               │
│           ├── Windows Toast (BurntToast)                            │
│           ├── ntfy Push (wenn aktiviert)                            │
│           └── Timer startet                                         │
│                                                                     │
│  t=0-30s  Polling alle 5 Sekunden                                   │
│           └── Wert fällt unter Schwelle? → Timer Reset              │
│                                                                     │
│  t=30s    STUFE 2 — Programme beenden                               │
│           ├── taskkill auf Prozessliste                             │
│           └── Alert: "Programme beendet"                            │
│                                                                     │
│  t=30-90s Polling weiter                                            │
│           └── Wert fällt unter Schwelle? → Timer Reset              │
│                                                                     │
│  t=90s    STUFE 3 — Notabschaltung                                  │
│           ├── Alert: "NOTABSCHALTUNG"                               │
│           ├── 2s warten (damit ntfy noch rausgeht)                  │
│           └── shutdown.exe /s /f /t 0                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Timer-Logik

- Jeder Sensor hat einen eigenen Timer
- Reset wenn Wert unter Schwelle fällt
- Warn-Reset mit Hysterese (erst bei 95% der Warn-Schwelle)
- GPU-Fan nur unter Last bewertet (Semi-Passiv-Modus bei Idle ist normal)

---

## Zusatzmeldungen (Info-Alerts)

Neben den CPU/GPU-Warn/Crit-Sensoren gibt es rein informative Meldungen. Sie lösen **nie** Stufe 2/3 aus.

- **All-Temps-Report** (`$EnableAllTempsReport`): scannt *jede* Temperatur, die HWiNFO meldet (Kerne, VRM, Chipsatz, SSD, Mainboard, RAM, ...), und meldet, was gerade auffällig ist. Zwei Kategorien mit eigenen Schwellen (`$AllTempsReportThreshold_CpuGpu = 75`, `$AllTempsReportThreshold_Board = 55`). Alles, was zu keiner passt, nutzt die CPU/GPU-Schwellen. Mit Hysterese: Eine Meldung entsteht beim Report-Wert und endet erst unter dem niedrigeren Track-Wert (60 / 50), damit ein Wert, der um die Schwelle pendelt, nicht jede Runde meldet. Die Sensoren mit eigener Warn/Crit-Logik (CPU, GPU, Hotspot, Memory Junction) sind hier ausgenommen.
- **Performance-Limit-Flags** (`$EnablePerfLimitAlerts`, nur NVIDIA): Meldung bei Wechsel von "aus" auf "an" und zurück für Power-, Thermal-, Reliability-Voltage- und Max-Operating-Voltage-Limit.
- **Warnungen** der CPU/GPU-Sensoren (Warn-Schwelle erreicht) laufen ebenfalls hier durch.
- **Digest:** All diese Info-Meldungen werden gesammelt und höchstens alle `$InfoAlertCooldownMinutes` (45) als **eine** Sammelmeldung verschickt. Die allererste geht sofort raus. **Kritische Alarme (Crit, Stufe 2/3, Fail-safe) sind davon nicht betroffen und gehen immer sofort raus.**

---

## Simulation / Dry-Run

Stufe 2 und 3 lassen sich testen, ohne den PC zu überhitzen:

```powershell
# CPU-Temperatur vortäuschen (95 Grad). Impliziert -DryRun: es wird nichts beendet oder heruntergefahren.
pwsh -File .\HWiNFO-ThermalGuard.ps1 -SimulateTemp 95

# Echte Messwerte, aber Stufe 2/3 nur ins Log schreiben
pwsh -File .\HWiNFO-ThermalGuard.ps1 -DryRun
```

- Stufe 2 loggt `[DRYRUN] would kill: <prozess>`, Stufe 3 loggt `[DRYRUN] would run: shutdown.exe ...` und beendet danach das Script (Simulation zu Ende).
- Toast und ntfy kommen wirklich an, der Titel trägt `[DRYRUN]`. So lässt sich auch der Benachrichtigungsweg testen.
- Der Zeitablauf ist echt: Alarm sofort, "Stufe 2" nach `$Stage2Delay`, "Shutdown" nach `$Stage3Delay`.
- Watchdog, Update-Check und Update-Installer sind in diesem Modus aus. Die Instanz zählt für den Launcher nicht als "ThermalGuard läuft" und kann parallel zur echten laufen. Sie schreibt in dasselbe Log (Zeilen mit `[DRYRUN]`).
- Das Failsafe bei Datenverlust nutzt dieselben Aktionen und wird damit ebenfalls nur geloggt.

---

## Firewall-Härtung

RemoteHWInfo ist ein allgemeiner HTTP/JSON-Server ohne dokumentierte Option, nur auf Loopback zu lauschen. Mit `$EnableFirewallHardening = $true` (Standard) legt das Script daher beim Start eine eingehende Blockier-Regel `HWiNFO-ThermalGuard-Block-NonLocal-60000` für den Port (`$RemoteHWInfoPort`) an, damit andere Geräte im Netz die Sensordaten nicht abrufen können. Das braucht Administratorrechte. Scheitert es, steht eine Warnung im Log. Wieder entfernen: `Remove-NetFirewallRule -DisplayName 'HWiNFO-ThermalGuard-Block-NonLocal-60000'`. Kommt trotz Regel keine Verbindung zustande, setze `$EnableFirewallHardening = $false`.

---

## Logging

```text
%USERPROFILE%\HWiNFO-ThermalGuard\thermalguard.log
```

Beispiel (gekürzt):

```text
[2026-10-02 14:23:01] [INFO] HWiNFO Thermal Guard v1.51 started
[2026-10-02 14:23:01] [INFO] PowerShell:      7.6.1 (Core)
[2026-10-02 14:23:01] [INFO] GPU Profile:     NVIDIA
[2026-10-02 14:23:02] [INFO] HWiNFO64        [OK] Found: C:\Program Files\HWiNFO64\HWiNFO64.exe
[2026-10-02 14:23:04] [INFO] HTTP Endpoint   [OK] http://localhost:60000/json.json (263 readings)
[2026-10-02 14:23:06] [INFO] === HEALTHY: first successful sensor poll (3 temperature sensor(s) resolved) ===
[2026-10-02 15:41:22] [WARN] GPU Temperature: WARNING 84 degrees (threshold: 80)
[2026-10-02 15:42:05] [CRIT] GPU Temperature: CRITICAL value=91, timer started
```

Beim ersten erfolgreichen Poll steht außerdem ein **Self-Test** im Log: Für jeden überwachten Sensor, welche Messzeile (Label, `sensorIndex`, Einheit, Wert) er aufgelöst hat, und eine WARN-Zeile für jeden, den die echte Abfrage nicht auflösen kann.

Rotation bei 10 MB. Es bleiben die letzten 10 rotierten Logs (`thermalguard_*.log`) erhalten, ältere werden gelöscht (`$MaxLogFilesToKeep`).

---

## Dienste prüfen

PowerShell-Einzeiler (Status aller Dienste):

```powershell
"HWiNFO64: $(if(Get-Process HWiNFO64 -EA 0){'[OK]'}else{'[TOT]'})  |  RemoteHWInfo: $(if(Get-Process RemoteHWInfo -EA 0){'[OK]'}else{'[TOT]'})  |  ThermalGuard: $(if(Get-CimInstance Win32_Process|?{$_.CommandLine -match 'ThermalGuard'}){'[OK]'}else{'[TOT]'})"
```

## Dienste beenden

| Prozess | Beenden |
| --- | --- |
| ThermalGuard | Task-Manager → Details → `powershell.exe` / `pwsh.exe` mit ThermalGuard → Task beenden |
| RemoteHWInfo | Task-Manager → Details → `RemoteHWInfo.exe` → Task beenden |
| HWiNFO64 | Tray-Icon → Rechtsklick → Exit |

---

## Beispiel-Setups

### Setup A: Fox (RTX 5070 Ti + eigener ntfy-Server)

```powershell
$GPUProfile = "AUTO"      # erkennt NVIDIA automatisch
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.deine-domain.example"
$NTFY_TOPIC = "ha-system"
$EnableHWiNFO12hReset = $false   # HWiNFO Pro
```

### Setup B: Kollege (RX 6800 XT + kein ntfy)

```powershell
$GPUProfile = "AUTO"      # erkennt AMD automatisch
$EnableNtfy = $false
$EnableHWiNFO12hReset = $true    # HWiNFO Free
```

### Setup C: Kollege mit ntfy.sh (kostenlos)

```powershell
$GPUProfile = "AUTO"
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-hans"
```

---

## Watchdog + 12h-Reset

### Konfiguration

```powershell
$EnableWatchdog       = $true   # Prozess-Überwachung an/aus
$WatchdogIntervalSec  = 60     # Prüf-Intervall in Sekunden
$EnableHWiNFO12hReset = $true  # Automatischer Neustart vor 12h-Limit
$HWiNFOMaxRuntimeMin  = 690   # Neustart nach X Minuten (690 = 11.5h)
$EndpointUnhealthyCyclesBeforeRestart = 3   # so viele Zyklen ohne Daten, dann Neustart trotz laufender Prozesse
```

### Was der Watchdog macht

Alle 60 Sekunden (konfigurierbar) prüft der Watchdog:

| Prüfung | Aktion bei Fehler |
| --- | --- |
| HWiNFO64 Prozess weg | Automatischer Neustart + 15s warten |
| RemoteHWInfo Prozess weg | Automatischer Neustart + 5s warten |
| fipha Prozess weg (nur mit `$EnableFipha`) | Neustart, nur kurze Prüfung (blockiert die Schleife nicht lange) |
| Prozesse laufen, aber Endpoint liefert keine Daten | Nach 3 Zyklen in Folge: HWiNFO64 + RemoteHWInfo hart neu starten |
| HWiNFO Laufzeit > 11.5h | Beide Prozesse stoppen → HWiNFO neu → RemoteHWInfo neu (**aufgeschoben**, solange ein Stufe-2/3-Timer oder der Daten-Failsafe läuft) |
| Endpoint offline | Sofortiger Watchdog-Check (normales Intervall überspringen) |

Derselbe 60s-Takt stößt (intern selbst auf `$UpdateCheckIntervalHours` gedrosselt) auch den Update-Check an, siehe oben.

**Grenze:** Ein Neustart-Schritt blockiert die Polling-Schleife für die Dauer seiner Wartezeiten (HWiNFO 15 s + RemoteHWInfo 5 s, beim 12h-Reset zusammen ca. 25-30 s). Das fällt fast immer mit der Zeit zusammen, in der HWiNFO ohnehin keine Daten liefert, weil es gerade neu startet. Ein laufender Stufe-2/3-Timer wird dabei nicht angehalten, nur seine Auswertung verzögert sich um höchstens diese Zeit. Der 12h-Reset selbst wird bei laufendem Timer aufgeschoben.

### 12h-Reset Ablauf

```text
HWiNFO läuft seit 11.5h
    ├── Alert: "HWiNFO 12h-Reset"
    ├── HWiNFO64 stoppen
    ├── RemoteHWInfo stoppen (braucht neues Shared Memory)
    ├── 3s warten
    ├── HWiNFO64 neu starten
    ├── 15s warten auf Sensor-Init
    ├── RemoteHWInfo neu starten
    ├── 5s warten auf HTTP-Server
    └── Timer zurücksetzen → nächster Reset in 11.5h
```

Bei Fehlern wird ein Alert gesendet. ThermalGuard beendet sich **nicht** — es pollt weiter und versucht beim nächsten Watchdog-Durchlauf erneut.

### HWiNFO Pro

Wer HWiNFO Pro hat kann den 12h-Reset abschalten:

```powershell
$EnableHWiNFO12hReset = $false
```

---

## Sensor-Labels prüfen (bei Problemen)

Falls ein Sensor nicht erkannt wird, Labels manuell prüfen:

1. HWiNFO64 + RemoteHWInfo müssen laufen
2. Browser → `http://localhost:60000/json.json`
3. Strg+F → nach dem Sensor suchen
4. `labelOriginal` im JSON mit `SensorMatch` im Script vergleichen

Schneller: Beim ersten Poll schreibt das Script einen **Self-Test** ins Log (siehe [Logging](#logging)), der zeigt, welche Zeile je Sensor aufgelöst wurde. Eine WARN-Zeile `NOT resolved by the live lookup` heißt: Label, Index oder Einheit passt nicht.

`Get-SensorDump.ps1` sammelt alle Sensoren mit Einheit (inkl. Unicode-Codepoints der Einheit) und min/avg/max über 120 s in einer Datei, siehe [Sensordaten beisteuern](#sensordaten-beisteuern).

**Einheiten-Filter:** Für die überwachten Temperatur-Sensoren (CPU, GPU, Hotspot, Memory Junction) wird eine Messzeile nur verwendet, wenn ihre Einheit wie eine Temperatur aussieht (`°C`, `C`, `deg C`; bis zu drei Zeichen vor dem `C`, damit auch ein durch Kodierungsfehler verstümmeltes Gradzeichen durchgeht). Watt, Volt, RPM, Prozent und Ähnliches werden nie als Temperatur genommen, auch wenn das Label passt. Beispiel: `CPU Package` darf nicht auf `CPU Package Power` fallen.

---

## Troubleshooting

### "HWiNFO64 konnte nicht installiert werden"

winget braucht den Windows Update Service. Prüfen:

```powershell
Get-Service wuauserv | Select-Object Status, StartType
```

Falls deaktiviert:

```powershell
Set-Service wuauserv -StartupType Manual; Start-Service wuauserv
```

Oder HWiNFO64 manuell installieren: [hwinfo.com/download](https://www.hwinfo.com/download/)

### "RemoteHWInfo Download fehlgeschlagen"

GitHub nicht erreichbar oder Firewall blockt. Manuell:
[RemoteHWInfo v0.5 ZIP](https://github.com/Demion/remotehwinfo/releases/download/v0.5/RemoteHWInfo_v0.5.zip)

### "HTTP-Endpoint nicht erreichbar"

- HWiNFO64 im Sensors-only Modus?
- Shared Memory aktiv? (wird automatisch per Registry gesetzt)
- RemoteHWInfo Prozess läuft? → Task-Manager → Details
- Port 60000 frei? → `netstat -ano | findstr 60000`

### "Sensor fehlt" im Log

Der `SensorMatch`-String passt nicht zu den tatsächlichen Labels. Siehe "Sensor-Labels prüfen".

### Toast-Benachrichtigungen kommen nicht

BurntToast installiert?

```powershell
Get-Module -ListAvailable -Name BurntToast
```

Falls nicht:

```powershell
Install-Module BurntToast -Force -Scope CurrentUser
```

Windows Fokus-Assistent muss **aus** sein: Windows Einstellungen → System → Benachrichtigungen → Fokus-Assistent → Aus

### "SensorMatch ... only matched readings whose unit is not a temperature"

Der Einheiten-Filter hat alle Messzeilen für dieses Label abgelehnt, weil keine eine Temperatur-Einheit hat. Prüfen, was HWiNFO für den Sensor liefert (`Get-SensorDump.ps1`, dort steht die Einheit samt Codepoints). Eine fälschlich abgelehnte Temperatur-Einheit bitte als Issue melden. Der Sensor gilt bis dahin als fehlend (Alarm nach ca. 15 s, mit Failsafe ggf. Abschaltung nach 7 min).

### ThermalGuard hat den PC ohne Überhitzung heruntergefahren

Im Log nach `Data-loss fail-safe` suchen. Das Failsafe fährt herunter, wenn das Script 7 Minuten lang keinen gültigen CPU/GPU-Wert hatte (HWiNFO weg, Label passt nach Hardwaretausch nicht mehr, Shared Memory aus). Ursache beheben oder das Failsafe mit `$EnableDataLossFailsafe = $false` abschalten.

### Update wurde nicht bereitgestellt oder installiert

Im Log nach `Update install` suchen. Häufige Gründe: kein SHA-256 am Release (`$UpdateRequireHash`), Hash passt nicht, Syntaxfehler, oder `HWiNFO-ThermalGuard.failed-vX.Y.txt` existiert (diese Version ist bei dir schon einmal durchgefallen: Datei löschen, um sie erneut zu erlauben). Mit `$EnableAutoInstall` wird ein Update ohne verifizierten Hash nie automatisch installiert.

---

## PowerShell-Kompatibilität

| Feature | PS 5.1 | PS 7+ |
| --- | --- | --- |
| Script-Ausführung | ✅ | ✅ |
| BurntToast | ✅ | ✅ |
| Auto-Scan | ✅ | ✅ |
| Auto-Download | ✅ | ✅ |
| winget | ✅ | ✅ |

Die `.bat` erkennt automatisch ob `pwsh.exe` (PS7) verfügbar ist und bevorzugt es. Fallback auf `powershell.exe` (PS5.1).

---

## Architektur

```text
Task "HWiNFO Thermal Guard" (Anmeldung + alle 5 Min)   oder   Start-HWiNFO-Remote.vbs
    │
    └── Start-HWiNFO-Remote.bat      (Schnellcheck, PowerShell-Erkennung, Unblock)
            │
            └── HWiNFO-ThermalGuard.ps1      (einziger Supervisor)
                    │
                    ├── Shared Memory Registry setzen
                    ├── Software-Check: HWiNFO64, RemoteHWInfo, BurntToast, (fipha), ntfy, Firewall-Regel
                    │       ├── HWiNFO64 suchen → winget install
                    │       └── RemoteHWInfo suchen → GitHub ZIP
                    ├── Watchdog alle 60s
                    │       ├── HWiNFO64 / RemoteHWInfo / fipha alive? → Neustart wenn down
                    │       ├── Endpoint liefert Daten? → nach 3 Zyklen Neustart
                    │       ├── HWiNFO > 11.5h? → 12h-Reset (aufgeschoben bei Stufe 2/3)
                    │       └── Update-Check (gedrosselt) → optional Download + Bereitstellen
                    ├── Polling-Loop alle 5s
                    │       ├── CPU / GPU / Hotspot / Memory Junction / Lüfter: Warn (Digest), Crit (sofort)
                    │       ├── Stufe 1: Toast + ntfy → Stufe 2: Prozesse beenden → Stufe 3: shutdown.exe
                    │       ├── Daten-Failsafe: blind → Stufe 2 → Stufe 3
                    │       ├── All-Temps-Report + Perf-Limit-Flags → Info-Digest
                    │       └── Health-Marker im Log (für den Update-Installer)
                    │
                    └── Log → %USERPROFILE%\HWiNFO-ThermalGuard\

Approve-ThermalGuardUpdate.ps1 ──► HWiNFO-ThermalGuard.ps1 -InstallPendingUpdate   (eigener Prozess:
                                   prüfen → sichern → tauschen → Health-Check → ggf. Rollback)
Get-SensorDump.ps1             ──► liest nur, schreibt ThermalGuard-SensorDump.txt
```

---

## Limitierungen

- **HWiNFO Free 12h-Limit** wird automatisch behandelt: Watchdog startet HWiNFO + RemoteHWInfo vor Ablauf neu (Standard: nach 11.5h). Mit `$EnableHWiNFO12hReset = $false` abschaltbar. HWiNFO Pro hat kein Limit.
- **RemoteHWInfo Watchdog** erkennt Abstürze und startet den Prozess automatisch neu. Bei Endpoint-Ausfall wird sofort ein Watchdog-Check erzwungen.
- **Neustart-Schritte blockieren das Polling** kurz (siehe [Watchdog](#was-der-watchdog-macht)). Das passiert fast nur, während HWiNFO ohnehin keine Daten liefert.
- **GPU Fan 2** (NVIDIA, wo vorhanden) wird erst überwacht, nachdem er in diesem Lauf einmal über 0 RPM gesehen wurde. So löst ein Phantom-Sensor mit 0 RPM auf einer Karte ohne echten zweiten Lüfter nie Stufe 2/3 aus. Ein Lüfter, der schon beim Start tot ist, wird deshalb nicht erkannt. Fehlt `GPU Fan2`, gibt es keinen Alarm.
- **Daten-Failsafe** kann einen unnötigen Shutdown auslösen, wenn die Sensor-Anbindung länger als 7 Minuten ausfällt (siehe [Failsafe](#failsafe-bei-datenverlust)). Dafür ist man dann nicht mehr blind unterwegs.
- **Update-Hash** schützt nicht vor einem kompromittierten Repo, siehe [Update-Sicherheit](#update-sicherheit).
- **ntfy-Passwort** steht im Klartext im Script (siehe [ntfy](#ntfy-einrichten)).
- **12V-2x6 Pin-Überwachung** ist bei der ASUS Prime 5070 Ti nicht nativ über Software-Telemetrie verfügbar (Power Detector+ nur bei ROG Astral/Matrix).
- **Toast im Vollbild** wird von Windows unterdrückt. ntfy ist die Absicherung.
- **Auto-Download** benötigt Internetzugang beim ersten Start. Danach offline-fähig.

---

## Sensordaten beisteuern

Intel CPUs und Intel Arc GPUs fehlen aktuell, weil die genauen HWiNFO-Sensor-Labels
auf echter Hardware bestätigt werden müssen, statt geraten zu werden. Wer eins
davon hat, kann in 2-3 Minuten helfen: [Issue-Formular öffnen](../../issues/new?template=report.yml),
`Get-SensorDump.ps1` laufen lassen (sampled 120s, idealerweise mit
Last/Spiel dazwischen) und den Inhalt der erzeugten Datei `%USERPROFILE%\HWiNFO-ThermalGuard\ThermalGuard-SensorDump.txt` reinpasten (vorher kurz durchlesen: enthält Hardware-Modellnamen, aber keinen Benutzer- oder Rechnernamen).

`Get-SensorDump.ps1` setzt voraus, dass HWiNFO64 + RemoteHWInfo bereits laufen
(also `HWiNFO-ThermalGuard.ps1` bzw. den `.bat`-Launcher vorher starten und
laufen lassen) — läuft RemoteHWInfo nicht, bricht das Script sofort mit einer
klaren Fehlermeldung ab, statt 120 Sekunden lang stumm zu retryen.

---

## Lizenz

Frei verwendbar. Keine Gewährleistung — thermischer Schutz ist am Ende immer Sache der Hardware.
