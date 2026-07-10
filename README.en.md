# HWiNFO Thermal Guard v1.48

[Deutsch](README.md) | **[English](README.en.md)**

Automatic thermal protection for Windows gaming PCs.  
Monitors CPU and GPU sensors in real time via HWiNFO + RemoteHWInfo and reacts to critical temperatures with a three-stage escalation: **Warning → kill processes → emergency shutdown.**

**Hardware support:** 🟢 full support · 🟠 base monitoring only · 🔴 not yet supported

[![AMD CPU](https://img.shields.io/badge/AMD_CPU-full_support-brightgreen?logo=amd&logoColor=white)](#gpu-profile)
[![NVIDIA GPU](https://img.shields.io/badge/NVIDIA_GPU-full_support-brightgreen?logo=nvidia&logoColor=white)](#gpu-profile)
[![AMD GPU](https://img.shields.io/badge/AMD_GPU-full_support-brightgreen?logo=amd&logoColor=white)](#gpu-profile)
[![Intel CPU](https://img.shields.io/badge/Intel_CPU-not_supported-red?logo=intel&logoColor=white)](#contributing-sensor-data)
[![Intel Arc GPU](https://img.shields.io/badge/Intel_Arc_GPU-not_supported-red?logo=intel&logoColor=white)](#contributing-sensor-data)

**Details by generation/socket:**

| Architecture | Generation | Status |
| --- | --- | --- |
| AMD CPU (AM4) | Ryzen 1000-5000 (Zen-Zen 3) | ✅ Tested (5800X3D) |
| AMD CPU (AM5) | Ryzen 7000-9000 (Zen 4/5) | ⚠️ Same sensor label (`Tctl/Tdie`), should work, untested |
| NVIDIA GPU | RTX 50 (Blackwell) | ✅ Fully tested (5070 Ti), incl. memory junction temp + performance-limit flags |
| NVIDIA GPU | RTX 20/30/40 (Turing-Ada) | ⚠️ Base temp should work; memory junction temp isn't always reported by NVIDIA's drivers on older cards |
| AMD GPU | RX 9000 (RDNA4) | ✅ Base monitoring tested (9070 XT); memory junction temp + power run via the same AMD profile, but not separately confirmed on RDNA4 |
| AMD GPU | RX 6000/7000 (RDNA2/3) | ✅ Fully tested (6800 XT), incl. memory junction temp + power (TGP) |
| Intel CPU | all | ❌ Not supported (no Tctl/Tdie equivalent, different sensor names) |
| Intel Arc GPU | A-/B-series | ❌ Not supported |

> AMD GPU: full sensor coverage (temp/hotspot/fan/load/memory junction
> temp/power draw) confirmed on an RX 6800 XT via a sensor dump. The one
> remaining gap versus NVIDIA: the performance-limit flags, which HWiNFO
> only exposes for NVIDIA GPUs as dedicated yes/no sensors.

<!-- -->

> **Side note:** Given the current DRAM crisis and the resulting sky-high
> prices, keeping a closer eye on your hardware is worth it more than ever -
> ThermalGuard at least helps make sure RAM/GPU/CPU don't die early from
> overheating right when replacements are painfully expensive.

---

## Quick start (fresh PC, nothing installed)

1. Create the folder `C:\Tools\HWiNFO-ThermalGuard\`
2. Copy in all files:
   - `HWiNFO-ThermalGuard.ps1`
   - `Start-HWiNFO-Remote.bat`
   - `Start-HWiNFO-Remote.vbs`
3. Open `HWiNFO-ThermalGuard.ps1` → adjust the first few lines:

   ```powershell
   $GPUProfile = "AUTO"      # auto-detects GPU (or "NVIDIA" / "AMD")
   $EnableNtfy = $false      # no ntfy server? -> false
   ```

4. Right-click `Start-HWiNFO-Remote.bat` → **Run as administrator**
5. Done - anything missing gets installed automatically

---

## What gets installed automatically?

| Dependency | Method | Target |
| --- | --- | --- |
| **HWiNFO64** | `winget install` (silent) | Default install path |
| **RemoteHWInfo** | GitHub ZIP download + extract | `C:\Tools\RemoteHWInfo\` |
| **BurntToast** | `Install-Module` (PowerShell) | PS module path |

Auto-install only kicks in **if** the software isn't found. If it's already installed (anywhere), the existing path is used.

If winget fails for HWiNFO (e.g. Windows Update service disabled), the log shows a download link for manual install.

---

## File structure

```text
C:\Tools\HWiNFO-ThermalGuard\
├── HWiNFO-ThermalGuard.ps1      <- Main script
├── Start-HWiNFO-Remote.bat      <- Autostart chain
├── Start-HWiNFO-Remote.vbs      <- Invisible wrapper
└── README.md                    <- This documentation
```

---

## Setup in detail

### GPU profile

```powershell
$GPUProfile = "AUTO"      # Auto-detects NVIDIA or AMD (default)
$GPUProfile = "NVIDIA"    # Manual override: RTX 5070 Ti, RTX 4090, etc.
$GPUProfile = "AMD"       # Manual override: RX 9070 XT, RX 6800 XT, etc.
```

With `AUTO`, the script detects the GPU automatically via two methods:

1. **Windows WMI** (`Win32_VideoController`) - always works, even without HWiNFO
2. **HWiNFO JSON** (fallback) - reads the GPU name from the sensor data

The profiles automatically set the correct sensor labels:

| | NVIDIA | AMD |
| --- | --- | --- |
| GPU Temp | `GPU Temperature` | `GPU Temperature` |
| GPU Hotspot | Not available | `GPU Hot Spot Temperature` |
| GPU Fan | `GPU Fan1` | `GPU Fan` |
| GPU Load | `GPU Core Load` | `GPU Utilization` |
| GPU Memory Junction | `GPU Memory Junction Temperature` | `GPU Memory Junction Temperature` |
| GPU Power | `GPU Power` | `Total Graphics Power (TGP)` |

### Toggles

```powershell
$EnableCPU  = $true     # Monitor CPU temperature
$EnableGPU  = $true     # Monitor GPU temperature
$EnableNtfy = $true     # Push notifications via ntfy
```

### Setting up ntfy

**Your own server:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.your-domain.example"
$NTFY_TOPIC = "ha-system"
```

**No server of your own? Free via ntfy.sh:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-yourname"    # any name, just needs to be unique
```

Then install the ntfy app (Android/iOS), subscribe to the topic, done.

**Don't want ntfy:**

```powershell
$EnableNtfy = $false
```

Windows toast notifications always run, independent of ntfy.

### Update check (optional)

Periodically checks the GitHub repo for a newer version and alerts via toast + ntfy when one is out. Off by default.

```powershell
$EnableUpdateCheck        = $true
$UpdateCheckRepo          = "pol4rfuchs/ThermalGuard-hwinfo64"   # "owner/repo"
$UpdateCheckIntervalHours = 24
```

- Runs once at startup and then every `$UpdateCheckIntervalHours` hours (checked from the watchdog cycle, so long-running sessions past the 12h reset still pick up releases published in the meantime).
- Alerts about a new version **once**, not on every check, as long as you haven't updated yet.
- Network errors (e.g. offline) only get logged, no alert spam.
- Uses the same toast+ntfy infrastructure as the temperature alerts - the ntfy settings above apply here too, but the toast still fires even with `$EnableNtfy = $false`.

### Thresholds

Two ways to set CPU/GPU Warn+Crit:

**A) Recommended — fill in the one datasheet number, the rest is automatic:**

```powershell
$CPU_Tjmax       = 90     # e.g. 90 for a Ryzen 7 5800X3D - your CPU's datasheet
$GPU_MaxTempSpec = 88     # official max GPU temp from the manufacturer's spec page
```

This automatically computes:

```powershell
$CPU_WarnMarginC = 10   # Warn = Tjmax - 10
$CPU_CritMarginC = 3    # Crit = Tjmax - 3
$GPU_WarnMarginC = 8    # Warn = MaxTempSpec - 8
$GPU_CritMarginC = 2    # Crit = MaxTempSpec - 2
```

No more guessing which Warn/Crit number from a generic table "fits" - you only need the one official raw value, the script handles the margin.

**B) Manual, full control:**

Leave `$CPU_Tjmax` and `$GPU_MaxTempSpec` at `$null` (default) and set these directly instead:

```powershell
$CPU_WarnTemp    = 80     # CPU warning from here
$CPU_CritTemp    = 87     # CPU hard-stop from here
$GPU_WarnTemp    = 80     # GPU warning
$GPU_CritTemp    = 86     # GPU hard-stop
```

These are also exactly the fallback values that apply as long as `$CPU_Tjmax`/`$GPU_MaxTempSpec` are `$null` - existing configs from before this feature don't change.

Unaffected by A/B either way:

```powershell
$GPU_HotspotWarn = 95     # GPU hotspot warning (AMD only)
$GPU_HotspotCrit = 100    # GPU hotspot hard-stop (AMD only)
$GPU_FanWarnRPM  = 300    # Fan warning below this value under load
$GPU_FanCritRPM  = 0      # Fan hard-stop: 0 RPM under load
```

> **Important:** even with option A, the script doesn't replace your own
> research - `$CPU_Tjmax` (your CPU's datasheet) and `$GPU_MaxTempSpec`
> (the GPU manufacturer's spec page) still need to be looked up yourself;
> HWiNFO doesn't reliably report either as a sensor value. For comparison:
> the actual configuration in this repo is tuned for a Ryzen 7 5800X3D
> (Tjmax 90°C) and an RTX 5070 Ti (official maximum 88°C) - exactly the
> numbers used as the example for `$CPU_Tjmax`/`$GPU_MaxTempSpec` above.

### Timing

```powershell
$PollInterval = 5     # Seconds between polls
$Stage2Delay  = 30    # Seconds until processes are killed
$Stage3Delay  = 90    # Seconds until shutdown (total from trigger)
```

### Process list (stage 2)

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

Find process names in Task Manager under "Details", or via:

```powershell
Get-Process | Where-Object { $_.MainWindowTitle -ne "" }
```

### Paths (optional)

Usually not needed - the script scans automatically. Only set these if the software lives in an unusual location:

```powershell
$HWiNFO_Path       = ""    # empty = auto-scan
$RemoteHWInfo_Path  = ""    # empty = auto-scan
```

---

## Setting up autostart

### Method 1: shell:startup (recommended)

1. `.bat` and `.vbs` in the **same folder** (e.g. `C:\Tools\HWiNFO-ThermalGuard\`)
2. `Win+R` → `shell:startup` → Enter
3. Right-click `.vbs` → **Create shortcut** → move the shortcut into the startup folder

### What happens at startup

```text
Start-HWiNFO-Remote.vbs (invisible)
    └── Start-HWiNFO-Remote.bat
            ├── Detect PowerShell 7 or 5.1
            ├── Enable Shared Memory via registry
            ├── -Resolve: scan paths + download missing software
            ├── Start HWiNFO64 (or skip if running)
            ├── Wait 15s for sensor initialization
            ├── Start RemoteHWInfo (or skip if running)
            ├── Check HTTP endpoint
            └── Start ThermalGuard (or skip if running)
```

All processes have duplicate protection. The `.bat` can be run as many times as you like - whatever's already running gets skipped.

---

## Path scan order

### HWiNFO64

1. Manual override (`$HWiNFO_Path`)
2. `C:\Program Files\HWiNFO64\`
3. `C:\Program Files (x86)\HWiNFO64\`
4. `C:\Tools\HWiNFO64\`
5. `C:\Tools\`
6. Desktop
7. Downloads
8. System PATH
9. Auto-install via `winget install REALiX.HWiNFO`

### RemoteHWInfo

1. Manual override (`$RemoteHWInfo_Path`)
2. `C:\Tools\RemoteHWInfo\`
3. `C:\Tools\`
4. Desktop
5. Downloads
6. `Desktop\Software_Treiber_Games\Software+Tools\`
7. Script folder
8. Auto-download from GitHub → `C:\Tools\RemoteHWInfo\`

---

## 3-stage escalation

```text
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  t=0s     Critical threshold reached                                │
│           ├── Windows toast (BurntToast)                            │
│           ├── ntfy push (if enabled)                                │
│           └── Timer starts                                          │
│                                                                     │
│  t=0-30s  Polling every 5 seconds                                   │
│           └── Value drops below threshold? → Timer reset            │
│                                                                     │
│  t=30s    STAGE 2 — kill processes                                  │
│           ├── taskkill on process list                               │
│           └── Alert: "Processes killed"                             │
│                                                                     │
│  t=30-90s Polling continues                                         │
│           └── Value drops below threshold? → Timer reset            │
│                                                                     │
│  t=90s    STAGE 3 — emergency shutdown                              │
│           ├── Alert: "EMERGENCY SHUTDOWN"                           │
│           ├── Wait 2s (so ntfy still goes out)                      │
│           └── shutdown.exe /s /f /t 0                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Timer logic

- Every sensor has its own timer
- Reset when the value drops below the threshold
- Warn-reset uses hysteresis (only at 95% of the warn threshold)
- GPU fan is only evaluated under load (semi-passive mode at idle is normal)

---

## Logging

```text
%USERPROFILE%\HWiNFO-ThermalGuard\thermalguard.log
```

Example:

```text
[2026-05-18 14:23:01] [INFO] HWiNFO Thermal Guard v1.42 started
[2026-05-18 14:23:01] [INFO] PowerShell: 7.6.1 (Core)
[2026-05-18 14:23:01] [INFO] GPU profile: NVIDIA
[2026-05-18 14:23:02] [OK]   HWiNFO64 found: C:\Program Files\HWiNFO64\HWiNFO64.exe
[2026-05-18 14:23:03] [OK]   RemoteHWInfo found: C:\Tools\RemoteHWInfo\RemoteHWInfo.exe
[2026-05-18 14:23:04] [OK]   HTTP endpoint: 263 readings
[2026-05-18 15:41:22] [WARN] GPU Temperature WARNING: 84 degrees
[2026-05-18 15:42:05] [CRIT] GPU Temperature CRITICAL: 91 - timer started
```

Rotates at 10 MB.

---

## Checking services

PowerShell one-liner (status of all services):

```powershell
"HWiNFO64: $(if(Get-Process HWiNFO64 -EA 0){'[OK]'}else{'[DEAD]'})  |  RemoteHWInfo: $(if(Get-Process RemoteHWInfo -EA 0){'[OK]'}else{'[DEAD]'})  |  ThermalGuard: $(if(Get-CimInstance Win32_Process|?{$_.CommandLine -match 'ThermalGuard'}){'[OK]'}else{'[DEAD]'})"
```

## Stopping services

| Process | How to stop |
| --- | --- |
| ThermalGuard | Task Manager → Details → `powershell.exe` / `pwsh.exe` running ThermalGuard → End task |
| RemoteHWInfo | Task Manager → Details → `RemoteHWInfo.exe` → End task |
| HWiNFO64 | Tray icon → right-click → Exit |

---

## Example setups

### Setup A: Fox (RTX 5070 Ti + own ntfy server)

```powershell
$GPUProfile = "AUTO"      # auto-detects NVIDIA
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.your-domain.example"
$NTFY_TOPIC = "ha-system"
$EnableHWiNFO12hReset = $false   # HWiNFO Pro
```

### Setup B: Friend (RX 6800 XT + no ntfy)

```powershell
$GPUProfile = "AUTO"      # auto-detects AMD
$EnableNtfy = $false
$EnableHWiNFO12hReset = $true    # HWiNFO Free
```

### Setup C: Friend with ntfy.sh (free)

```powershell
$GPUProfile = "AUTO"
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-john"
```

---

## Watchdog + 12h reset

### Configuration

```powershell
$EnableWatchdog       = $true   # Process monitoring on/off
$WatchdogIntervalSec  = 60     # Check interval in seconds
$EnableHWiNFO12hReset = $true  # Automatic restart before the 12h limit
$HWiNFOMaxRuntimeMin  = 690   # Restart after X minutes (690 = 11.5h)
```

### What the watchdog does

Every 60 seconds (configurable) the watchdog checks:

| Check | Action on failure |
| --- | --- |
| HWiNFO64 process gone | Automatic restart + wait 15s |
| RemoteHWInfo process gone | Automatic restart + wait 5s |
| HWiNFO runtime > 11.5h | Stop both processes → restart HWiNFO → restart RemoteHWInfo |
| Endpoint offline | Immediate watchdog check (skips the normal interval) |

The same 60s cycle also triggers the update check (internally throttled to `$UpdateCheckIntervalHours`, see above).

### 12h reset sequence

```text
HWiNFO has been running for 11.5h
    +-- Alert: "HWiNFO 12h reset"
    +-- Stop HWiNFO64
    +-- Stop RemoteHWInfo (needs fresh Shared Memory)
    +-- Wait 3s
    +-- Restart HWiNFO64
    +-- Wait 15s for sensor init
    +-- Restart RemoteHWInfo
    +-- Wait 5s for the HTTP server
    +-- Reset timer -> next reset in 11.5h
```

An alert is sent on errors. ThermalGuard does **not** exit - it keeps polling and retries on the next watchdog cycle.

### HWiNFO Pro

If you have HWiNFO Pro you can disable the 12h reset:

```powershell
$EnableHWiNFO12hReset = $false
```

---

## Checking sensor labels (troubleshooting)

If a sensor isn't detected, check the labels manually:

1. HWiNFO64 + RemoteHWInfo must be running
2. Browser → `http://localhost:60000/json.json`
3. Ctrl+F → search for the sensor
4. Compare `labelOriginal` in the JSON against `SensorMatch` in the script

---

## Troubleshooting

### "HWiNFO64 could not be installed"

winget needs the Windows Update service. Check:

```powershell
Get-Service wuauserv | Select-Object Status, StartType
```

If disabled:

```powershell
Set-Service wuauserv -StartupType Manual; Start-Service wuauserv
```

Or install HWiNFO64 manually: [hwinfo.com/download](https://www.hwinfo.com/download/)

### "RemoteHWInfo download failed"

GitHub unreachable or blocked by a firewall. Manual download:
[RemoteHWInfo v0.5 ZIP](https://github.com/Demion/remotehwinfo/releases/download/v0.5/RemoteHWInfo_v0.5.zip)

### "HTTP endpoint unreachable"

- Is HWiNFO64 in sensors-only mode?
- Is Shared Memory active? (set automatically via registry)
- Is the RemoteHWInfo process running? → Task Manager → Details
- Is port 60000 free? → `netstat -ano | findstr 60000`

### "Sensor missing" in the log

The `SensorMatch` string doesn't match the actual labels. See "Checking sensor labels".

### Toast notifications don't show up

Is BurntToast installed?

```powershell
Get-Module -ListAvailable -Name BurntToast
```

If not:

```powershell
Install-Module BurntToast -Force -Scope CurrentUser
```

Windows Focus Assist must be **off**: Windows Settings → System → Notifications → Focus assist → Off

---

## PowerShell compatibility

| Feature | PS 5.1 | PS 7+ |
| --- | --- | --- |
| Script execution | Yes | Yes |
| BurntToast | Yes | Yes |
| Auto-scan | Yes | Yes |
| Auto-download | Yes | Yes |
| winget | Yes | Yes |

The `.bat` automatically detects whether `pwsh.exe` (PS7) is available and prefers it. Falls back to `powershell.exe` (PS5.1).

---

## Architecture

```text
Start-HWiNFO-Remote.vbs (shell:startup)
    │
    └── Start-HWiNFO-Remote.bat
            │
            ├── Detect PS version (pwsh or powershell)
            ├── Set Shared Memory registry key
            ├── -Resolve: scan paths + auto-download
            │       ├── Look for HWiNFO64 → winget install
            │       └── Look for RemoteHWInfo → GitHub ZIP
            │
            ├── Start HWiNFO64.exe
            ├── Start RemoteHWInfo.exe (hidden)
            └── Start HWiNFO-ThermalGuard.ps1 (hidden)
                    │
                    ├── Check/install BurntToast
                    ├── Check all processes + endpoint
                    ├── Watchdog every 60s
                    │       ├── HWiNFO64 alive? → restart if down
                    │       ├── RemoteHWInfo alive? → restart if down
                    │       ├── HWiNFO > 11.5h? → 12h reset
                    │       └── Update check (throttled to interval)
                    ├── Poll loop every 5s
                    │       ├── Stage 1: toast + ntfy
                    │       ├── Stage 2: taskkill
                    │       └── Stage 3: shutdown.exe
                    │
                    └── Log → %USERPROFILE%\HWiNFO-ThermalGuard\
```

---

## Limitations

- **HWiNFO Free 12h limit** is handled automatically: the watchdog restarts HWiNFO + RemoteHWInfo before it expires (default: after 11.5h). Can be disabled with `$EnableHWiNFO12hReset = $false`. HWiNFO Pro has no limit.
- **RemoteHWInfo watchdog** detects crashes and restarts the process automatically. An endpoint outage forces an immediate watchdog check.
- **12V-2x6 pin monitoring** isn't natively available via software telemetry on the ASUS Prime 5070 Ti (Power Detector+ is ROG Astral/Matrix only).
- **Toast in fullscreen** is suppressed by Windows. ntfy is the fallback.
- **Auto-download** needs internet access on first run. Works offline afterward.

---

## Contributing sensor data

Intel CPUs and Intel Arc GPUs are currently missing because the exact
HWiNFO sensor labels need to be confirmed on real hardware instead of
guessed. If you have one of these, you can help in 2-3 minutes:
[open the issue form](../../issues/new?template=report.yml), run
`Get-SensorDump.ps1` (samples for 120s, ideally with some load/a game
running partway through), and paste the output.

`Get-SensorDump.ps1` expects HWiNFO64 + RemoteHWInfo to already be running
(start `HWiNFO-ThermalGuard.ps1` or the `.bat` launcher first and leave it
running) - if RemoteHWInfo isn't running, the script now fails fast with a
clear message instead of silently retrying for 120 seconds.

---

## License

Free to use. No warranty - thermal protection is ultimately down to the hardware.
