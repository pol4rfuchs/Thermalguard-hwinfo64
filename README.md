# HWiNFO Thermal Guard v1.4

Automatic thermal protection for Windows gaming PCs.  
Monitors CPU and GPU sensors in real time via HWiNFO + RemoteHWInfo and responds to critical temperatures with a three-stage escalation: **Warning → Kill Processes → Emergency Shutdown.**

[![Wiki](https://img.shields.io/badge/Wiki-Documentation-blue?style=flat-square&logo=gitbook)](https://pol4rfuchs.codeberg.page/ha-appwikis/hwinfo-thermalguard/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![HWiNFO](https://img.shields.io/badge/HWiNFO-64-orange?style=flat-square)](https://www.hwinfo.com/)
[![License](https://img.shields.io/badge/License-Free-brightgreen?style=flat-square)](#license)

> 📖 **Full documentation, quick start guide and troubleshooting:**  
> **[pol4rfuchs.github.io/ha-appwikis/hwinfo-thermalguard](https://pol4rfuchs.github.io/ha-appwikis/)**

---

## Quick Start (fresh PC, nothing installed)

1. Create the folder `C:\Tools\HWiNFO-ThermalGuard\`
2. Copy all files into it:
   - `HWiNFO-ThermalGuard.ps1`
   - `Start-HWiNFO-Remote.bat`
   - `Start-HWiNFO-Remote.vbs`
3. Open `HWiNFO-ThermalGuard.ps1` → adjust the first few lines:

```powershell
$GPUProfile = "AUTO"      # auto-detects GPU (or set to "NVIDIA" / "AMD")
$EnableNtfy = $false      # no ntfy server? → false
```

4. Right-click `Start-HWiNFO-Remote.bat` → **Run as Administrator**
5. Done — everything missing will be installed automatically

---

## What Gets Installed Automatically?

| Dependency | Method | Destination |
|---|---|---|
| **HWiNFO64** | `winget install` (silent) | Default installation path |
| **RemoteHWInfo** | GitHub ZIP download + extract | `C:\Tools\RemoteHWInfo\` |
| **BurntToast** | `Install-Module` (PowerShell) | PS module path |

Auto-install only triggers if the software is **not already found**. If it's already installed (anywhere), the existing path is used.

If winget fails for HWiNFO (e.g. Windows Update Service is disabled), the log will show a manual download link.

---

## File Structure

```
C:\Tools\HWiNFO-ThermalGuard\
├── HWiNFO-ThermalGuard.ps1      ← Main script
├── Start-HWiNFO-Remote.bat      ← Autostart chain
├── Start-HWiNFO-Remote.vbs      ← Invisible wrapper
└── README.md                    ← This documentation
```

---

## Setup in Detail

### GPU Profile

```powershell
$GPUProfile = "AUTO"      # Auto-detects NVIDIA or AMD (default)
$GPUProfile = "NVIDIA"    # Manual override: RTX 5070 Ti, RTX 4090, etc.
$GPUProfile = "AMD"       # Manual override: RX 9070 XT, RX 6800 XT, etc.
```

With `AUTO`, the script detects the GPU via two methods:

1. **Windows WMI** (`Win32_VideoController`) — always works, even without HWiNFO
2. **HWiNFO JSON** (fallback) — reads GPU name from sensor data

Profiles automatically set the correct sensor labels:

| | NVIDIA | AMD |
|---|---|---|
| GPU Temp | `GPU Temperature` | `GPU Temperature` |
| GPU Hotspot | Not available | `GPU Hot Spot Temperature` |
| GPU Fan | `GPU Fan1` | `GPU Fan` |
| GPU Load | `GPU Core Load` | `GPU Utilization` |

### Toggles

```powershell
$EnableCPU  = $true     # Monitor CPU temperature
$EnableGPU  = $true     # Monitor GPU temperature
$EnableNtfy = $true     # Push notifications via ntfy
```

### Setting Up ntfy

**Own server:**
```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.example.com"
$NTFY_TOPIC = "thermalguard"
```

**No own server? Use ntfy.sh for free:**
```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-yourname"    # any name, just needs to be unique
```

Then install the ntfy app (Android/iOS), subscribe to the topic, done.

**Don't want ntfy at all:**
```powershell
$EnableNtfy = $false
```

Windows Toast notifications always run, independent of ntfy.

### Thresholds

```powershell
$CPU_WarnTemp    = 85     # CPU early warning above this
$CPU_CritTemp    = 91     # CPU hard stop above this
$GPU_WarnTemp    = 83     # GPU early warning
$GPU_CritTemp    = 90     # GPU hard stop
$GPU_HotspotWarn = 95     # GPU hotspot warning (AMD only)
$GPU_HotspotCrit = 100    # GPU hotspot hard stop (AMD only)
$GPU_FanWarnRPM  = 300    # Fan warning below this RPM under load
$GPU_FanCritRPM  = 0      # Fan hard stop: 0 RPM under load
```

**Reference values:**

| Component | Conservative | Standard | Aggressive |
|---|---|---|---|
| CPU Warn | 80°C | 85°C | 88°C |
| CPU Crit | 88°C | 91°C | 95°C |
| GPU Warn | 78°C | 83°C | 85°C |
| GPU Crit | 85°C | 90°C | 92°C |
| GPU Hotspot Warn | 90°C | 95°C | 97°C |
| GPU Hotspot Crit | 95°C | 100°C | 105°C |

### Timing

```powershell
$PollInterval = 5     # Seconds between polls
$Stage2Delay  = 30    # Seconds until processes are killed
$Stage3Delay  = 90    # Seconds until shutdown (total from trigger)
```

### Kill List (Stage 2)

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

Find process names in Task Manager under "Details" or via:
```powershell
Get-Process | Where-Object { $_.MainWindowTitle -ne "" }
```

### Paths (Optional)

Normally not needed — the script scans automatically. Only set these if the software is in an unusual location:

```powershell
$HWiNFO_Path       = ""    # empty = auto-scan
$RemoteHWInfo_Path  = ""    # empty = auto-scan
```

---

## Setting Up Autostart

### Method 1: shell:startup (recommended)

1. Place `.bat` and `.vbs` in the **same folder** (e.g. `C:\Tools\HWiNFO-ThermalGuard\`)
2. `Win+R` → `shell:startup` → Enter
3. Right-click the `.vbs` → **Create shortcut** → move the shortcut into the startup folder

### What Happens at Startup

```
Start-HWiNFO-Remote.vbs (invisible)
    └── Start-HWiNFO-Remote.bat
            ├── Detect PowerShell 7 or 5.1
            ├── Enable Shared Memory via Registry
            ├── -Resolve: scan paths + download missing software
            ├── Start HWiNFO64 (or skip if already running)
            ├── Wait 15s for sensor initialization
            ├── Start RemoteHWInfo (or skip if already running)
            ├── Check HTTP endpoint
            └── Start ThermalGuard (or skip if already running)
```

All processes have duplicate protection. The `.bat` can be run any number of times — anything already running is skipped.

---

## Path Scan Order

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
6. Script folder (subdirectory)
7. Script folder
8. Auto-download from GitHub → `C:\Tools\RemoteHWInfo\`

---

## 3-Stage Escalation

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  t=0s     Critical threshold reached                                │
│           ├── Windows Toast (BurntToast)                            │
│           ├── ntfy push (if enabled)                                │
│           └── Timer starts                                          │
│                                                                     │
│  t=0-30s  Polling every 5 seconds                                   │
│           └── Value drops below threshold? → Timer reset            │
│                                                                     │
│  t=30s    STAGE 2 — Kill processes                                  │
│           ├── taskkill on process list                               │
│           └── Alert: "Processes killed"                             │
│                                                                     │
│  t=30-90s Polling continues                                         │
│           └── Value drops below threshold? → Timer reset            │
│                                                                     │
│  t=90s    STAGE 3 — Emergency shutdown                              │
│           ├── Alert: "EMERGENCY SHUTDOWN"                           │
│           ├── Wait 2s (to let ntfy send)                            │
│           └── shutdown.exe /s /f /t 0                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Timer Logic

- Each sensor has its own independent timer
- Resets when the value drops below the threshold
- Warning reset uses hysteresis (only resets at 95% of the warning threshold)
- GPU fan is only evaluated under load (semi-passive mode at idle is normal)

---

## Logging

```
%USERPROFILE%\HWiNFO-ThermalGuard\thermalguard.log
```

Example:
```
[2026-05-18 14:23:01] [INFO] HWiNFO Thermal Guard v1.3 started
[2026-05-18 14:23:01] [INFO] PowerShell: 7.6.1 (Core)
[2026-05-18 14:23:01] [INFO] GPU profile: NVIDIA
[2026-05-18 14:23:02] [OK]   HWiNFO64 found: C:\Program Files\HWiNFO64\HWiNFO64.exe
[2026-05-18 14:23:03] [OK]   RemoteHWInfo found: C:\Tools\RemoteHWInfo\RemoteHWInfo.exe
[2026-05-18 14:23:04] [OK]   HTTP endpoint: 263 readings
[2026-05-18 15:41:22] [WARN] GPU Temperature WARNING: 84°C
[2026-05-18 15:42:05] [CRIT] GPU Temperature CRITICAL: 91°C — timer started
```

Rotates at 10 MB.

---

## Checking Services

PowerShell one-liner (status of all services):

```powershell
"HWiNFO64: $(if(Get-Process HWiNFO64 -EA 0){'[OK]'}else{'[DEAD]'})  |  RemoteHWInfo: $(if(Get-Process RemoteHWInfo -EA 0){'[OK]'}else{'[DEAD]'})  |  ThermalGuard: $(if(Get-CimInstance Win32_Process|?{$_.CommandLine -match 'ThermalGuard'}){'[OK]'}else{'[DEAD]'})"
```

## Stopping Services

| Process | How to stop |
|---|---|
| ThermalGuard | Task Manager → Details → `powershell.exe` / `pwsh.exe` with ThermalGuard → End task |
| RemoteHWInfo | Task Manager → Details → `RemoteHWInfo.exe` → End task |
| HWiNFO64 | Tray icon → Right-click → Exit |

---

## Example Setups

### Setup A: User A (RTX 5070 Ti + own ntfy server)

```powershell
$GPUProfile = "AUTO"      # auto-detects NVIDIA
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.example.com"
$NTFY_TOPIC = "thermalguard"
$EnableHWiNFO12hReset = $false   # HWiNFO Pro
```

### Setup B: Colleague (RX 6800 XT + no ntfy)

```powershell
$GPUProfile = "AUTO"      # auto-detects AMD
$EnableNtfy = $false
$EnableHWiNFO12hReset = $true    # HWiNFO Free
```

### Setup C: Colleague with ntfy.sh (free)

```powershell
$GPUProfile = "AUTO"
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-yourname"
```

---

## Watchdog + 12h Reset

### Configuration

```powershell
$EnableWatchdog       = $true   # Process monitoring on/off
$WatchdogIntervalSec  = 60     # Check interval in seconds
$EnableHWiNFO12hReset = $true  # Automatic restart before 12h limit
$HWiNFOMaxRuntimeMin  = 690   # Restart after X minutes (690 = 11.5h)
```

### What the Watchdog Does

Every 60 seconds (configurable), the watchdog checks:

| Check | Action on failure |
|---|---|
| HWiNFO64 process gone | Automatic restart + wait 15s |
| RemoteHWInfo process gone | Automatic restart + wait 5s |
| HWiNFO runtime > 11.5h | Stop both → restart HWiNFO → restart RemoteHWInfo |
| Endpoint offline | Immediate watchdog check (skip normal interval) |

### 12h Reset Sequence

```
HWiNFO has been running for 11.5h
    ├── Alert: "HWiNFO 12h reset"
    ├── Stop HWiNFO64
    ├── Stop RemoteHWInfo (needs new Shared Memory)
    ├── Wait 3s
    ├── Restart HWiNFO64
    ├── Wait 15s for sensor init
    ├── Restart RemoteHWInfo
    ├── Wait 5s for HTTP server
    └── Reset timer → next reset in 11.5h
```

On error, an alert is sent. ThermalGuard does **not** exit — it keeps polling and retries on the next watchdog cycle.

### HWiNFO Pro

Users with HWiNFO Pro can disable the 12h reset:

```powershell
$EnableHWiNFO12hReset = $false
```

---

## Checking Sensor Labels (Troubleshooting)

If a sensor isn't being detected, check labels manually:

1. HWiNFO64 + RemoteHWInfo must be running
2. Browser → `http://localhost:60000/json.json`
3. Ctrl+F → search for the sensor
4. Compare `labelOriginal` in the JSON with `SensorMatch` in the script

---

## Troubleshooting

### "HWiNFO64 could not be installed"

winget requires the Windows Update Service. Check:
```powershell
Get-Service wuauserv | Select-Object Status, StartType
```
If disabled:
```powershell
Set-Service wuauserv -StartupType Manual; Start-Service wuauserv
```

Or install HWiNFO64 manually: [hwinfo.com/download](https://www.hwinfo.com/download/)

### "RemoteHWInfo download failed"

GitHub unreachable or firewall blocking. Manual download:  
[RemoteHWInfo v0.5 ZIP](https://github.com/Demion/remotehwinfo/releases/download/v0.5/RemoteHWInfo_v0.5.zip)

### "HTTP endpoint not reachable"

- Is HWiNFO64 running in sensors-only mode?
- Is Shared Memory active? (set automatically via Registry)
- Is RemoteHWInfo running? → Task Manager → Details
- Is port 60000 free? → `netstat -ano | findstr 60000`

### "Sensor missing" in log

The `SensorMatch` string doesn't match the actual labels. See "Checking Sensor Labels" above.

### Toast notifications not showing

Is BurntToast installed?
```powershell
Get-Module -ListAvailable -Name BurntToast
```
If not:
```powershell
Install-Module BurntToast -Force -Scope CurrentUser
```

Focus Assist must be **off**: Windows Settings → System → Notifications → Focus Assist → Off

---

## PowerShell Compatibility

| Feature | PS 5.1 | PS 7+ |
|---|---|---|
| Script execution | ✅ | ✅ |
| BurntToast | ✅ | ✅ |
| Auto-scan | ✅ | ✅ |
| Auto-download | ✅ | ✅ |
| winget | ✅ | ✅ |

The `.bat` automatically detects whether `pwsh.exe` (PS7) is available and prefers it. Falls back to `powershell.exe` (PS5.1).

---

## Architecture

```
Start-HWiNFO-Remote.vbs (shell:startup)
    │
    └── Start-HWiNFO-Remote.bat
            │
            ├── Detect PS version (pwsh or powershell)
            ├── Set Shared Memory Registry key
            ├── -Resolve: scan paths + auto-download
            │       ├── Find HWiNFO64 → winget install
            │       └── Find RemoteHWInfo → GitHub ZIP
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
                    │       └── HWiNFO > 11.5h? → 12h reset
                    ├── Polling loop every 5s
                    │       ├── Stage 1: Toast + ntfy
                    │       ├── Stage 2: taskkill
                    │       └── Stage 3: shutdown.exe
                    │
                    └── Log → %USERPROFILE%\HWiNFO-ThermalGuard\
```

---

## Limitations

- **HWiNFO Free 12h limit** is handled automatically: the watchdog restarts HWiNFO + RemoteHWInfo before the limit expires (default: after 11.5h). Disable with `$EnableHWiNFO12hReset = $false`. HWiNFO Pro has no limit.
- **RemoteHWInfo watchdog** detects crashes and automatically restarts the process. On endpoint failure, an immediate watchdog check is triggered.
- **12V-2x6 pin monitoring** is not natively available via software telemetry on the ASUS Prime 5070 Ti (Power Detector+ is ROG Astral/Matrix only).
- **Toast in fullscreen** is suppressed by Windows. ntfy is the backup.
- **Auto-download** requires internet access on first run. Fully offline afterwards.

---

## License

Free to use. No warranty — thermal protection is ultimately always a matter of hardware.

---

## fipha Integration (HWiNFO → MQTT → Home Assistant)

### What is fipha?

[fipha](https://github.com/mhwlng/fipha) is an MQTT bridge for HWiNFO64 Shared Memory. It reads sensor data and publishes it via MQTT Discovery to Home Assistant, enabling real-time monitoring of CPU/GPU/liquid cooling sensors in your smart home.

### Installation

1. [Download fipha v0.0.2.0](https://github.com/mhwlng/fipha/releases/tag/v0.0.2.0)
2. Extract to `C:\Tools\fip-ha-0.0.2.0\`
3. Configure `mqtt.config`:
   ```json
   {
     "mqttBroker": "192.168.1.10",
     "mqttPort": 1883,
     "mqttUser": "mqtt_fipha",
     "mqttPassword": "yourpassword"
   }
   ```
4. Create `HWINFO.inc` with sensor mappings (see below)

### Auto-Start with ThermalGuard

fipha is automatically started alongside the other services when:

```powershell
# In HWiNFO-ThermalGuard.ps1:
$fipha_Path = ""              # empty = auto-scan
$EnableFipha = $true          # toggle on/off
```

**Scan paths:**
1. `C:\Tools\fip-ha-0.0.2.0\fipha.exe`
2. `C:\Tools\fipha\fipha.exe`
3. `%USERPROFILE%\Desktop\fipha\fipha.exe`
4. `%USERPROFILE%\Downloads\fipha\fipha.exe`

### HWINFO.inc Sensor Mapping

Example for Ryzen CPU + NVIDIA GPU with liquid cooling:

```ini
[MySystem]
SensorType=0xf00aa900,0x0,Water Cooling,Water Cooling
SensorMatch=0x1000000,Water Temperature,temperature,sensor.mysystem_water_cooling_temp
SensorMatch=0x8000000,Water Flow,flow,sensor.mysystem_water_cooling_flow
SensorMatch=0x8000001,Conductivity,conductivity,sensor.mysystem_water_cooling_conductivity
SensorMatch=0x7000000,Water Quality,quality,sensor.mysystem_water_cooling_quality

SensorType=0xf0000501,0x0,Temperature,CPU
SensorMatch=0x1000000,CPU (Tctl/Tdie),temperature,sensor.mysystem_temperature_cpu
SensorMatch=0x1000008,CPU CCD1 (Tdie),temperature,sensor.mysystem_temperature_cpu_ccd

SensorType=0xe0002000,0x0,Temperature,GPU
SensorMatch=0x1000000,GPU Temperature,temperature,sensor.mysystem_temperature_gpu
SensorMatch=0x1000004,GPU Memory Junction Temperature,temperature,sensor.mysystem_temperature_gpu_mem
```

### Home Assistant Package

Entities appear automatically in HA via MQTT Discovery:
- `sensor.mysystem_water_cooling_temp`
- `sensor.mysystem_water_cooling_flow`
- `sensor.mysystem_water_cooling_conductivity`
- `sensor.mysystem_water_cooling_quality`
- `sensor.mysystem_temperature_cpu`
- `sensor.mysystem_temperature_gpu`

### Troubleshooting

**fipha won't start:**
- Path found correctly by auto-scan? Check logs
- Toggle `$EnableFipha = $true` set?
- Malwarebytes firewall: allow fipha.exe outbound on port 1883

**No MQTT connection:**
- Mosquitto broker running? (port 1883 reachable?)
- mqtt.config credentials correct?
- `mqtt_fipha` user created in HA?

**Entities missing in HA:**
- HWINFO.inc sensor IDs correct? (check via `http://localhost:60000/json.json`)
- HWiNFO64 Shared Memory active? (auto-enabled via Registry)
