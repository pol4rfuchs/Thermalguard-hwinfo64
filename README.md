# HWiNFO Thermal Guard v1.48

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
3. `HWiNFO-ThermalGuard.ps1` öffnen → die ersten Zeilen anpassen:

   ```powershell
   $GPUProfile = "AUTO"      # erkennt GPU automatisch (oder "NVIDIA" / "AMD")
   $EnableNtfy = $false      # kein ntfy-Server? → false
   ```

4. `Start-HWiNFO-Remote.bat` per Rechtsklick → **Als Administrator ausführen**
5. Fertig — alles was fehlt wird automatisch installiert

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
├── HWiNFO-ThermalGuard.ps1      ← Hauptscript
├── Start-HWiNFO-Remote.bat      ← Autostart-Kette
├── Start-HWiNFO-Remote.vbs      ← Unsichtbar-Wrapper
└── README.md                    ← Diese Dokumentation
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
$EnableCPU  = $true     # CPU-Temperatur überwachen
$EnableGPU  = $true     # GPU-Temperatur überwachen
$EnableNtfy = $true     # Push-Benachrichtigungen via ntfy
```

### ntfy einrichten

**Eigener Server:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.your-domain.example"
$NTFY_TOPIC = "ha-system"
```

**Kein eigener Server? Kostenlos über ntfy.sh:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-deinname"    # beliebiger Name, muss nur einzigartig sein
```

Dann die ntfy-App installieren (Android/iOS), Topic subscriben, fertig.

**Kein ntfy gewünscht:**

```powershell
$EnableNtfy = $false
```

Windows Toast-Benachrichtigungen laufen immer, unabhängig von ntfy.

### Update-Check (optional)

Prüft periodisch das GitHub-Repo auf eine neuere Version und meldet sich per Toast + ntfy, wenn eine da ist. Standardmäßig **aus**.

```powershell
$EnableUpdateCheck        = $true
$UpdateCheckRepo          = "pol4rfuchs/ThermalGuard-hwinfo64"   # "owner/repo"
$UpdateCheckIntervalHours = 24
```

- Läuft einmal beim Start und danach alle `$UpdateCheckIntervalHours` Stunden weiter (geprüft aus dem Watchdog-Takt heraus, damit auch lange Sessions über den 12h-Reset hinweg mitbekommen, wenn zwischenzeitlich was released wurde).
- Meldet eine neue Version **einmal**, nicht bei jedem Check erneut, solange nicht upgedatet wird.
- Netzwerkfehler (z.B. offline) landen nur im Log, es gibt keinen Alert-Spam.
- Nutzt für die Meldung dieselbe Toast+ntfy-Infrastruktur wie die Temperatur-Alerts — die ntfy-Einstellungen von oben gelten auch hier, der Toast kommt aber auch mit `$EnableNtfy = $false`.

### Schwellwerte

```powershell
$CPU_WarnTemp    = 85     # CPU Vorwarnung ab hier
$CPU_CritTemp    = 91     # CPU Hard-Stop ab hier
$GPU_WarnTemp    = 83     # GPU Vorwarnung
$GPU_CritTemp    = 90     # GPU Hard-Stop
$GPU_HotspotWarn = 95     # GPU Hotspot Vorwarnung (nur AMD)
$GPU_HotspotCrit = 100    # GPU Hotspot Hard-Stop (nur AMD)
$GPU_FanWarnRPM  = 300    # Fan-Warnung unter diesem Wert bei Last
$GPU_FanCritRPM  = 0      # Fan Hard-Stop: 0 RPM bei Last
```

**Richtwerte:**

| Komponente | Konservativ | Standard | Aggressiv |
| --- | --- | --- | --- |
| CPU Warn | 80°C | 85°C | 88°C |
| CPU Crit | 88°C | 91°C | 95°C |
| GPU Warn | 78°C | 83°C | 85°C |
| GPU Crit | 85°C | 90°C | 92°C |
| GPU Hotspot Warn | 90°C | 95°C | 97°C |
| GPU Hotspot Crit | 95°C | 100°C | 105°C |

> **Wichtig:** Das sind grobe Orientierungswerte, keine fertige Konfiguration
> zum Copy-Pasten. Die tatsächlich sinnvollen Werte hängen von **deiner**
> exakten CPU/GPU ab (Tjmax laut Hersteller-Datenblatt bei der CPU, offizielle
> maximale GPU-Temperatur laut Hersteller bei der Grafikkarte) und sollten
> mit Marge darunter gesetzt werden - nicht einfach eine Spalte übernehmen.
> Zum Vergleich: die tatsächliche Konfiguration in diesem Repo ist auf einen
> Ryzen 7 5800X3D (Tjmax 90°C) und eine RTX 5070 Ti (offizielles Maximum
> 88°C) abgestimmt und liegt deshalb quer über alle drei Spalten verteilt,
> nicht in einer einzigen. Miss/prüfe deine eigenen Werte, statt diese
> Tabelle oder das Repo-Beispiel 1:1 zu übernehmen.

### Timing

```powershell
$PollInterval = 5     # Sekunden zwischen Abfragen
$Stage2Delay  = 30    # Sekunden bis Programme beendet werden
$Stage3Delay  = 90    # Sekunden bis Shutdown (gesamt ab Trigger)
```

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

### Methode 1: shell:startup (empfohlen)

1. `.bat` und `.vbs` im **gleichen Ordner** (z.B. `C:\Tools\HWiNFO-ThermalGuard\`)
2. `Win+R` → `shell:startup` → Enter
3. Rechtsklick auf `.vbs` → **Verknüpfung erstellen** → Verknüpfung in den startup-Ordner verschieben

### Was beim Start passiert

```text
Start-HWiNFO-Remote.vbs (unsichtbar)
    └── Start-HWiNFO-Remote.bat
            ├── PowerShell 7 oder 5.1 erkennen
            ├── Shared Memory per Registry aktivieren
            ├── -Resolve: Pfade scannen + fehlende Software downloaden
            ├── HWiNFO64 starten (oder überspringen wenn läuft)
            ├── 15s warten auf Sensor-Initialisierung
            ├── RemoteHWInfo starten (oder überspringen wenn läuft)
            ├── HTTP-Endpoint prüfen
            └── ThermalGuard starten (oder überspringen wenn läuft)
```

Alle Prozesse haben Duplikat-Schutz. Die `.bat` kann beliebig oft ausgeführt werden — was schon läuft wird übersprungen.

---

## Pfad-Scan Reihenfolge

### HWiNFO64

1. Manueller Override (`$HWiNFO_Path`)
2. `C:\Program Files\HWiNFO64\`
3. `C:\Program Files (x86)\HWiNFO64\`
4. `C:\Tools\HWiNFO64\`
5. `C:\Tools\`
6. Desktop
7. Downloads
8. System PATH
9. Auto-Install via `winget install REALiX.HWiNFO`

### RemoteHWInfo

1. Manueller Override (`$RemoteHWInfo_Path`)
2. `C:\Tools\RemoteHWInfo\`
3. `C:\Tools\`
4. Desktop
5. Downloads
6. `Desktop\Software_Treiber_Games\Software+Tools\`
7. Script-Ordner
8. Auto-Download von GitHub → `C:\Tools\RemoteHWInfo\`

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

## Logging

```text
%USERPROFILE%\HWiNFO-ThermalGuard\thermalguard.log
```

Beispiel:

```text
[2026-05-18 14:23:01] [INFO] HWiNFO Thermal Guard v1.42 gestartet
[2026-05-18 14:23:01] [INFO] PowerShell: 7.6.1 (Core)
[2026-05-18 14:23:01] [INFO] GPU-Profil: NVIDIA
[2026-05-18 14:23:02] [OK]   HWiNFO64 Gefunden: C:\Program Files\HWiNFO64\HWiNFO64.exe
[2026-05-18 14:23:03] [OK]   RemoteHWInfo Gefunden: C:\Tools\RemoteHWInfo\RemoteHWInfo.exe
[2026-05-18 14:23:04] [OK]   HTTP-Endpoint: 263 Readings
[2026-05-18 15:41:22] [WARN] GPU Temperature VORWARNUNG: 84 Grad
[2026-05-18 15:42:05] [CRIT] GPU Temperature KRITISCH: 91 — Timer gestartet
```

Rotation bei 10 MB.

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
$NTFY_URL   = "https://ntfy.your-domain.example"
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
```

### Was der Watchdog macht

Alle 60 Sekunden (konfigurierbar) prüft der Watchdog:

| Prüfung | Aktion bei Fehler |
| --- | --- |
| HWiNFO64 Prozess weg | Automatischer Neustart + 15s warten |
| RemoteHWInfo Prozess weg | Automatischer Neustart + 5s warten |
| HWiNFO Laufzeit > 11.5h | Beide Prozesse stoppen → HWiNFO neu → RemoteHWInfo neu |
| Endpoint offline | Sofortiger Watchdog-Check (normales Intervall überspringen) |

Derselbe 60s-Takt stößt (intern selbst auf `$UpdateCheckIntervalHours` gedrosselt) auch den Update-Check an, siehe oben.

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
Start-HWiNFO-Remote.vbs (shell:startup)
    │
    └── Start-HWiNFO-Remote.bat
            │
            ├── PS-Version erkennen (pwsh oder powershell)
            ├── Shared Memory Registry setzen
            ├── -Resolve: Pfade scannen + Auto-Download
            │       ├── HWiNFO64 suchen → winget install
            │       └── RemoteHWInfo suchen → GitHub ZIP
            │
            ├── HWiNFO64.exe starten
            ├── RemoteHWInfo.exe starten (hidden)
            └── HWiNFO-ThermalGuard.ps1 starten (hidden)
                    │
                    ├── BurntToast prüfen/installieren
                    ├── Alle Prozesse + Endpoint prüfen
                    ├── Watchdog alle 60s
                    │       ├── HWiNFO64 alive? → Neustart wenn down
                    │       ├── RemoteHWInfo alive? → Neustart wenn down
                    │       ├── HWiNFO > 11.5h? → 12h-Reset
                    │       └── Update-Check (gedrosselt auf Intervall)
                    ├── Polling-Loop alle 5s
                    │       ├── Stufe 1: Toast + ntfy
                    │       ├── Stufe 2: taskkill
                    │       └── Stufe 3: shutdown.exe
                    │
                    └── Log → %USERPROFILE%\HWiNFO-ThermalGuard\
```

---

## Limitierungen

- **HWiNFO Free 12h-Limit** wird automatisch behandelt: Watchdog startet HWiNFO + RemoteHWInfo vor Ablauf neu (Standard: nach 11.5h). Mit `$EnableHWiNFO12hReset = $false` abschaltbar. HWiNFO Pro hat kein Limit.
- **RemoteHWInfo Watchdog** erkennt Abstürze und startet den Prozess automatisch neu. Bei Endpoint-Ausfall wird sofort ein Watchdog-Check erzwungen.
- **12V-2x6 Pin-Überwachung** ist bei der ASUS Prime 5070 Ti nicht nativ über Software-Telemetrie verfügbar (Power Detector+ nur bei ROG Astral/Matrix).
- **Toast im Vollbild** wird von Windows unterdrückt. ntfy ist die Absicherung.
- **Auto-Download** benötigt Internetzugang beim ersten Start. Danach offline-fähig.

---

## Sensordaten beisteuern

Intel CPUs und Intel Arc GPUs fehlen aktuell, weil die genauen HWiNFO-Sensor-Labels
auf echter Hardware bestätigt werden müssen, statt geraten zu werden. Wer eins
davon hat, kann in 2-3 Minuten helfen: [Issue-Formular öffnen](../../issues/new?template=report.yml),
`Get-SensorDump.ps1` laufen lassen (sampled 120s, idealerweise mit
Last/Spiel dazwischen) und die Ausgabe reinpasten.

`Get-SensorDump.ps1` setzt voraus, dass HWiNFO64 + RemoteHWInfo bereits laufen
(also `HWiNFO-ThermalGuard.ps1` bzw. den `.bat`-Launcher vorher starten und
laufen lassen) — läuft RemoteHWInfo nicht, bricht das Script sofort mit einer
klaren Fehlermeldung ab, statt 120 Sekunden lang stumm zu retryen.

---

## Lizenz

Frei verwendbar. Keine Gewährleistung — thermischer Schutz ist am Ende immer Sache der Hardware.
