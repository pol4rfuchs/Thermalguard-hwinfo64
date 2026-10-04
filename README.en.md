# HWiNFO Thermal Guard v1.53

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
   - `Install-ScheduledTask.ps1` (sets up autostart)
   - `Approve-ThermalGuardUpdate.ps1` (only needed if you use update download)
   - `Get-SensorDump.ps1` (optional, only for [contributing sensor data](#contributing-sensor-data))
3. Open `HWiNFO-ThermalGuard.ps1` → adjust the first few lines:

   ```powershell
   $GPUProfile = "AUTO"      # auto-detects GPU (or "NVIDIA" / "AMD")
   $EnableNtfy = $false      # no ntfy server? -> false
   ```

4. Set up autostart: run `Install-ScheduledTask.ps1` from an **administrator PowerShell** (see [Autostart](#setting-up-autostart)).
   For a quick test, right-click `Start-HWiNFO-Remote.bat` → **Run as administrator** also works
5. Done - anything missing (HWiNFO64, RemoteHWInfo, BurntToast) gets installed automatically

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
├── HWiNFO-ThermalGuard.ps1          ← Main script
├── Start-HWiNFO-Remote.bat          ← Launcher (quick check, PowerShell detection)
├── Start-HWiNFO-Remote.vbs          ← Invisible wrapper
├── Install-ScheduledTask.ps1        ← Sets up the autostart task (once, as admin)
├── Approve-ThermalGuardUpdate.ps1   ← Installs a staged update (update download)
├── Get-SensorDump.ps1               ← Optional: collect sensor data for a GitHub issue
└── README.md                        ← This documentation
```

With update download, these appear automatically next to the main script:

```text
HWiNFO-ThermalGuard.pending-vX.Y.ps1          ← staged, not yet active update
HWiNFO-ThermalGuard.pending-vX.Y.ps1.sha256   ← the hash that was verified at download time
HWiNFO-ThermalGuard.backup-vX.Y.ps1           ← backup of version X.Y (the version the file contains)
HWiNFO-ThermalGuard.failed-vX.Y.txt           ← version X.Y failed its health check (rolled back)
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
$EnableCPU   = $true     # monitor CPU temperature
$EnableGPU   = $true     # monitor GPU temperature
$EnableNtfy  = $true     # push notifications via ntfy
$EnableFipha = $false    # also start and supervise fipha (optional, see below)
```

**fipha** ([mhwlng/fipha](https://github.com/mhwlng/fipha)) publishes HWiNFO sensors to Home Assistant via MQTT discovery. It is an extra and not part of the thermal protection: ThermalGuard only starts and supervises the process if you set `$EnableFipha = $true`. fipha needs its own `mqtt.config` next to `fipha.exe`. The path is searched like the other programs (`$Fipha_Path`, otherwise `C:\Tools\fipha\` and `C:\Tools\`). A missing or crashing fipha is never a reason for stage 2/3.

### Setting up ntfy

**Own server:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.your-domain.example"
$NTFY_TOPIC = "ha-system"
```

**No own server? Free via ntfy.sh:**

```powershell
$EnableNtfy = $true
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "thermalguard-yourname"    # any name, just has to be unique
```

Then install the ntfy app (Android/iOS), subscribe to the topic, done.

**Server with access control (auth):**

```powershell
$NTFY_Token    = "tk_..."     # access token, sent as "Authorization: Bearer" (preferred)
# or instead of a token:
$NTFY_User     = "name"       # HTTP Basic
$NTFY_Password = "password"
```

The token wins if both are set. All empty = open topic. The credentials sit in plain text in the script, so prefer a token that may only write to this topic over your main password.

**Don't want ntfy:**

```powershell
$EnableNtfy = $false
```

Windows toast notifications always work, independent of ntfy.

### Update check and update install (optional)

**Everything is off** by default. Three levels, each switchable on its own:

```powershell
$EnableUpdateCheck        = $true     # 1) report: toast + ntfy when a newer release exists
$UpdateCheckRepo          = "pol4rfuchs/ThermalGuard-hwinfo64"   # "owner/repo"
$UpdateCheckIntervalHours = 24

$EnableAutoDownload       = $true     # 2) download, verify, stage - but do NOT activate
$EnableAutoInstall        = $false    # 3) swap in the staged update automatically (not recommended)

$UpdateRequireHash        = $true     # a SHA-256 from the release is mandatory (default)
$UpdateBackupsToKeep      = 3         # backups of old versions (at least 1 is always kept)
$UpdateHealthCheckTimeoutSec = 90     # how long the installer waits for the new version
```

**1) Check** (`$EnableUpdateCheck`)

- Runs once at startup and then every `$UpdateCheckIntervalHours` hours (checked from the watchdog cycle, so long-running sessions past the 12h reset still notice a release in between).
- Alerts about a new version **once**, not on every check, as long as you haven't updated yet.
- Network errors (e.g. offline) only get logged, no alert spam.
- Uses the same toast+ntfy infrastructure as the temperature alerts, and the toast still fires even with `$EnableNtfy = $false`.

**2) Download and staging** (`$EnableAutoDownload`)

1. Downloads `HWiNFO-ThermalGuard.ps1` from the release (fallback: the raw file at the tag).
2. **Verifies the SHA-256** against the hash published with the release: an asset `HWiNFO-ThermalGuard.ps1.sha256` (contents: the hash, optionally followed by the file name) or an asset `SHA256SUMS` in the usual `<hash>  <file>` format.
3. Checks the **syntax** (parser, nothing is executed).
4. Backs up the running file as `HWiNFO-ThermalGuard.backup-vX.Y.ps1`, where `X.Y` is the version the file **contains**.
5. Stages the update as `HWiNFO-ThermalGuard.pending-vX.Y.ps1` (with a `.sha256` file next to it) and tells you via toast + ntfy.

A failed download is retried at the next check. A version that was rejected (hash mismatch, syntax error, no hash) is not downloaded again at every interval within one run (after the guard restarts it is evaluated once more).

**3) Install** (manual or automatic)

*Manually (recommended):* from an **administrator PowerShell** in the script folder

```powershell
powershell -ExecutionPolicy Bypass -File .\Approve-ThermalGuardUpdate.ps1
```

The script shows the version, SHA-256, hash check and syntax check of the staged update and asks for confirmation (`-Yes` skips the question, `-ListOnly` only shows). Then the installer of the running script does the work:

```text
re-verify the staged file's hash → re-check syntax
  → fresh backup of the running file (backup-v<running version>)
  → disable the task, stop the old instance
  → swap
  → enable the task, start the new version
  → wait up to 90 s for the health marker in the log
        ├── found:     alert "ThermalGuard updated"
        └── not found: ROLLBACK (restore the backup, restart, alert "rolling back",
                       write failed-vX.Y.txt so the same version is not installed again in a loop)
```

The **health marker** is the log line `=== HEALTHY: first successful sensor poll (...) ===`. The new version only writes it after its first poll in which **all** primary temperature sensors (CPU and GPU, as far as enabled) deliver a valid reading, i.e. the guard is not blind. "Software Check complete" is deliberately not enough: that line is logged on failure too.

*Automatically* (`$EnableAutoInstall = $true`, requires `$EnableAutoDownload = $true`): the same installer, without you confirming. **Not recommended for a script whose job is to shut your PC down on overheating.**

If you run via `shell:startup` instead of the task, the installer starts the new version through `Start-HWiNFO-Remote.vbs`.

#### Update safety

- **Never while hot:** an update is neither checked, staged nor installed while any sensor is in a stage 2/3 timer or the [data-loss fail-safe](#data-loss-fail-safe) is counting. Overheat protection always comes first.
- **The hash is not a trust anchor.** It comes from the same release as the file. It protects against a corrupted download or one tampered with in transit, **not** against a compromised repo or maintainer account. If you do not control the repo yourself, leave `$EnableAutoInstall` off and look at the file before running `Approve`.
- **Without a hash:** with `$UpdateRequireHash = $true` (default) nothing is staged. With `$false` the update is staged as **UNVERIFIED** and is **never auto-installed**, not even with `$EnableAutoInstall = $true`. The installer also requires `$UpdateRequireHash = $false` if no `.sha256` file sits next to the staged file.
- **Tampering after download:** right before the swap the installer checks the staged file once more against the stored `.sha256` file.
- **The rollback source is always the file that was running right before the swap**, also for the second, third update.
- **First round:** the installer runs from the *old* file, so improvements to the installer itself only take effect on the update *from* the new version. Do the step to v1.51 by hand (replace the file).
- Between "old instance stopped" and "first poll of the new one" (normally well under a minute) nothing watches the temperatures: do not install on a hot or heavily loaded PC.

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
$GPU_FanStopMinTempC = 60 # fan warning/hard-stop only count from this GPU temperature
```

The fan hard-stop needs **load (≥ `$GPULoadThreshold`) and** a GPU temperature of at least `$GPU_FanStopMinTempC`. Cards with a zero-RPM mode (e.g. RTX 50, RX 6000/7000) stop their fans on purpose while the GPU is cool, even at moderate load; that is not a fault and triggers neither a warning nor stage 2/3.

> **Important:** even with option A, the script doesn't replace your own
> research - `$CPU_Tjmax` (your CPU's datasheet) and `$GPU_MaxTempSpec`
> (the GPU manufacturer's spec page) still need to be looked up yourself;
> HWiNFO doesn't reliably report either as a sensor value. For comparison:
> the actual configuration in this repo is tuned for a Ryzen 7 5800X3D
> (Tjmax 90°C) and an RTX 5070 Ti (official maximum 88°C) - exactly the
> numbers used as the example for `$CPU_Tjmax`/`$GPU_MaxTempSpec` above.

### Timing

```powershell
$PollInterval = 5     # seconds between polls
$Stage2Delay  = 30    # seconds until programs are killed
$Stage3Delay  = 90    # seconds until shutdown (total from trigger)
```

### Data-loss fail-safe

Without sensor data ThermalGuard is blind. It used to only raise alerts while the stage 2/3 timers (which need a reading) froze: if HWiNFO died in the middle of a heat spike, nothing happened any more. Being blind now counts too:

```powershell
$EnableDataLossFailsafe = $true
$DataLossStage2Sec      = 180   # after 3 min blind: kill the process list (like stage 2)
$DataLossShutdownSec    = 420   # after 7 min blind: emergency shutdown (like stage 3)
```

- **Blind** means: no valid value for `CPU Tctl/Tdie` (if `$EnableCPU`) or `GPU Temperature` (if `$EnableGPU`). So: endpoint unreachable, HWiNFO dead, label not found, unit is not a temperature, value outside -20..150 °C.
- The counter starts on the first blind poll and resets as soon as valid values are back. Normal watchdog restarts (HWiNFO about 25 s, 12h reset about 30 s) stay far below the 180 s.
- While the counter runs there is no update check, and the 12h reset is deferred.
- The normal alerts ("data source offline", "Sensor missing") still arrive long before.
- **After a hardware swap:** check the sensor labels in the self-test log (see [Checking sensor labels](#checking-sensor-labels-troubleshooting)). If a label does not match, the guard would be blind and the fail-safe shuts down after 7 minutes. During a swap set `$EnableGPU = $false` as before.
- Turn off: `$EnableDataLossFailsafe = $false` (old behavior: alert only).
- **Boot-loop breaker:** if the guard can never read a valid CPU/GPU value (label no longer matches, Intel CPU), the fail-safe would otherwise shut the PC down 7 minutes after every logon. Each fail-safe shutdown is therefore recorded in `%USERPROFILE%\HWiNFO-ThermalGuard\failsafe-shutdowns.txt`. If there were `$FailsafeMaxConsecutiveShutdowns` (2) of them within `$FailsafeLoopWindowMinutes` (60) without a single healthy poll in between, the guard **no longer shuts down** on data loss: it alerts urgently (every 15 minutes) and logs `shutdown SUPPRESSED`. The PC is unprotected until the sensor data is fixed. Stage 2 (process list) stays active. The first healthy poll clears the record. Turn off: `$FailsafeMaxConsecutiveShutdowns = 0`.

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

### Method 1: Scheduled Task (recommended)

1. Put all files in one folder (e.g. `C:\Tools\HWiNFO-ThermalGuard\`)
2. Run once from an **administrator PowerShell**:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-ScheduledTask.ps1
   ```

This creates the task `HWiNFO Thermal Guard`. It starts at logon **with highest privileges, without a UAC prompt**, and also runs from a **time trigger every 5 minutes** (**self-heal**): if the guard is running, the launcher exits silently. If the guard crashed, it starts it again within 5 minutes at the latest. Before, a crashed guard stayed dead until the next logon.

Why a separate time trigger? A repetition attached to the logon trigger only starts at the next logon, so a task created in a running session did not repeat at all at first. The time trigger starts right away and keeps going after a reboot (duration 10 years, after that just run `Install-ScheduledTask.ps1` again).

- Different interval: `-RepeatMinutes 10`. No repetition (start at logon only): `-RepeatMinutes 0`.
- At the end the script reads back what Windows actually stored. A green line `Next scheduled run: ...` means the repetition is active. Yellow means it is stored, but Windows shows no next run yet.
- Test: kill the guard (`Stop-Process` on the PowerShell process running `HWiNFO-ThermalGuard.ps1`) and wait at most 5 minutes. The PC is unprotected during that time, so test while idle.
- Test right away: `Start-ScheduledTask -TaskName 'HWiNFO Thermal Guard'`
- **Do not also** put the `.vbs` in `shell:startup`, or the chain starts twice.

### Method 2: shell:startup (no self-heal)

1. `.bat` and `.vbs` in the **same folder**
2. `Win+R` → `shell:startup` → Enter
3. Right-click the `.vbs` → **Create shortcut** → move the shortcut into the startup folder

Downsides: no UAC-free start with administrator rights (the script needs them for `shutdown.exe` and for killing processes) and no repetition after a crash. Only sensible if your account already starts elevated without a UAC prompt.

### What happens at startup

```text
Task (logon + every 5 min)   or   Start-HWiNFO-Remote.vbs (invisible)
    └── Start-HWiNFO-Remote.bat
            ├── quick check: ThermalGuard already running? → exit silently
            ├── detect PowerShell 7 or 5.1
            ├── unblock the known script files (Mark-of-the-Web)
            └── start HWiNFO-ThermalGuard.ps1 (hidden)
                    ├── enable Shared Memory via registry
                    ├── scan paths, download missing software
                    ├── start HWiNFO64, RemoteHWInfo (and fipha) if they are not running
                    └── from here on: monitoring + watchdog
```

The `.bat` does **not** start or check HWiNFO64, RemoteHWInfo or fipha itself: only `HWiNFO-ThermalGuard.ps1` does. The `.bat` can be run any number of times. If the guard is already running nothing happens. The duplicate check ignores installer and dry-run instances (`-InstallPendingUpdate`, `-DryRun`, `-SimulateTemp`). The log of the **last real start sequence** is in `%USERPROFILE%\HWiNFO-ThermalGuard\autostart.log`; the silent repetitions do not overwrite it.

---

## Path scan order

Only a fixed list of folders is scanned (each including subfolders down to depth 3, the largest matching file wins). Desktop and Downloads are **deliberately not** searched (security): if your install is there, set the `*_Path` override or move it to `C:\Tools\`.

### HWiNFO64

1. Manual override (`$HWiNFO_Path`)
2. `C:\Program Files\HWiNFO64\`
3. `C:\Program Files (x86)\HWiNFO64\`
4. `C:\Tools\HWiNFO64\`
5. `C:\Tools\` (incl. subfolders)
6. System PATH
7. Auto-install via `winget install REALiX.HWiNFO`

### RemoteHWInfo

1. Manual override (`$RemoteHWInfo_Path`)
2. `C:\Tools\RemoteHWInfo\`
3. `C:\Tools\` (incl. subfolders, finds e.g. `C:\Tools\RemoteHWInfo_v0.5\`)
4. System PATH
5. Auto-download from GitHub → `C:\Tools\RemoteHWInfo\` (the download is pinned to a fixed SHA-256, `$RemoteHWInfoZipSha256`; a different file is not unpacked)

### fipha (only with `$EnableFipha = $true`)

1. Manual override (`$Fipha_Path`)
2. `C:\Tools\fipha\`
3. `C:\Tools\` (incl. subfolders)

If fipha is not found there is only a warning in the log.

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
│           └── shutdown.exe /s /f /t 10                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Timer logic

- Every sensor has its own timer
- Reset when the value drops below the threshold
- Warn-reset uses hysteresis (only at 95% of the warn threshold)
- GPU fan is only evaluated under load (semi-passive mode at idle is normal)

---

## Additional alerts (info alerts)

Besides the CPU/GPU warn/crit sensors there are purely informational alerts. They **never** trigger stage 2/3.

- **All-temps report** (`$EnableAllTempsReport`): scans *every* temperature HWiNFO reports (cores, VRM, chipset, SSD, mainboard, RAM, ...) and reports what is currently noteworthy. Two categories with their own thresholds (`$AllTempsReportThreshold_CpuGpu = 75`, `$AllTempsReportThreshold_Board = 55`). Anything that fits neither uses the CPU/GPU thresholds. With hysteresis: an alert starts at the report value and only ends below the lower track value (60 / 50), so a value hovering around the threshold does not report every round. The sensors with their own warn/crit logic (CPU, GPU, hotspot, memory junction) are excluded here.
- **Performance-limit flags** (`$EnablePerfLimitAlerts`, NVIDIA only): alert when the power, thermal, reliability-voltage or max-operating-voltage limit switches on and off again.
- **Warnings** of the CPU/GPU sensors (warn threshold reached) go through here as well.
- **Digest:** all these info alerts are collected and sent as **one** summary at most every `$InfoAlertCooldownMinutes` (45). The very first one goes out immediately. **Critical alerts (crit, stage 2/3, fail-safe) are not affected and always go out immediately.**

---

## Simulation / dry run

Stage 2 and 3 can be tested without overheating the PC:

```powershell
# Pretend the CPU temperature is 95 degrees. Implies -DryRun: nothing is killed or shut down.
pwsh -File .\HWiNFO-ThermalGuard.ps1 -SimulateTemp 95

# Real readings, but stage 2/3 are only written to the log
pwsh -File .\HWiNFO-ThermalGuard.ps1 -DryRun
```

- Stage 2 logs `[DRYRUN] would kill: <process>`, stage 3 logs `[DRYRUN] would run: shutdown.exe ...` and then the script exits (simulation over).
- Toast and ntfy really arrive, with `[DRYRUN]` in the title. That also tests the notification path.
- Timing is real: alert at once, "stage 2" after `$Stage2Delay`, "shutdown" after `$Stage3Delay`.
- Watchdog, update check and update installer are off in this mode. The instance does not count as "ThermalGuard is running" for the launcher and can run next to the real one. It writes to the same log (lines with `[DRYRUN]`).
- The data-loss fail-safe uses the same actions and is therefore only logged, too.

### Automated behavior tests

`tests/Run-Tests.ps1` runs the real script as a child process against a mock sensor endpoint (`tests/MockEndpoint.ps1`, data from `tests/fixtures/sensors.json`) and checks its log, e.g. "fans stopped on a cool GPU: no alarm", "a critical sensor vanishes: escalation keeps running", "an exception in a subsystem: protection keeps running".

```powershell
pwsh -File .\tests\Run-Tests.ps1                  # all scenarios (about 5 minutes)
pwsh -File .\tests\Run-Tests.ps1 -Only 'fan-*'    # a selection
```

For this the script is copied to a temp folder and patched there (other port and log folder, short stage delays, toasts, kill list and `shutdown.exe` stubbed). The real installation is not touched. Exit code = number of failed scenarios. In GitHub Actions it runs as the *Behavior Tests* workflow.

---

## Firewall hardening

RemoteHWInfo is a generic HTTP/JSON server without a documented option to listen on loopback only. With `$EnableFirewallHardening = $true` (default) the script therefore creates an inbound block rule `HWiNFO-ThermalGuard-Block-NonLocal-60000` for the port (`$RemoteHWInfoPort`) at startup, so other devices on the network cannot fetch the sensor data. This needs administrator rights. If it fails there is a warning in the log. To remove it: `Remove-NetFirewallRule -DisplayName 'HWiNFO-ThermalGuard-Block-NonLocal-60000'`. Access via `localhost` (including the guard's own) is not affected by the rule. A reader on **another** device, e.g. a Home Assistant host, is blocked as well. If you need that, or the connection fails despite the rule, set `$EnableFirewallHardening = $false`.

---

## Permission check (running with administrator rights)

The guard runs **elevated** through the scheduled task and starts HWiNFO64, RemoteHWInfo and fipha with the same rights. If a standard user (or a non-elevated program of your account) can overwrite one of these files, it can replace it and gain administrator rights at the next start. That also applies when **you** own the folder: an owner can always rewrite the permissions.

- **At startup** the script only checks, read-only, the folders of the script and of the programs it starts (`$EnableExposureCheck`) and logs `Security [OK]` or `Security [WARN] <path> can be modified by non-administrators`.
- **Fixing:** `Install-ScheduledTask.ps1` runs the same check and lists the folders. With `-FixPermissions` (in an **elevated** PowerShell, after a confirmation; `-Yes` skips it) it sets them to: Administrators and SYSTEM full control, Users read/execute only, owner Administrators, no inherited entries. The HWiNFO64 folder is only reported, never changed. It refuses folders under `C:\Windows` and drive roots.
- Afterwards, editing the scripts in those folders needs an elevated shell or editor.

By hand, for a single folder (elevated PowerShell), **in exactly this order**:

```powershell
# 1) the folder itself only, WITHOUT /T
icacls "C:\Tools\RemoteHWInfo_v0.5" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX"
# 2) remove the user account's own entry (/grant:r does not remove it)
icacls "C:\Tools\RemoteHWInfo_v0.5" /remove "$env:COMPUTERNAME\$env:USERNAME"
# 3) everything below inherits from the folder
icacls "C:\Tools\RemoteHWInfo_v0.5\*" /reset /T /C
# 4) owner = Administrators
icacls "C:\Tools\RemoteHWInfo_v0.5" /setowner "*S-1-5-32-544" /T /C
```

> **Warning:** do not use `icacls <folder> /inheritance:r /grant:r ... /T` as a single command. It leaves every **file** in the folder with an empty permission list: nobody can read or start it any more. Repair if it happened: steps 2 to 4 above (as the owner of the files, step 3 also works without administrator rights).

---

## Logging

```text
%USERPROFILE%\HWiNFO-ThermalGuard\thermalguard.log
```

Example (shortened):

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

The first successful poll also writes a **self-test** to the log: for every monitored sensor, which reading (label, `sensorIndex`, unit, value) it resolved to, and a WARN line for every sensor the real lookup cannot resolve.

Rotation at 10 MB. The last 10 rotated logs (`thermalguard_*.log`) are kept, older ones are deleted (`$MaxLogFilesToKeep`).

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
$EnableWatchdog       = $true   # process supervision on/off
$WatchdogIntervalSec  = 60     # check interval in seconds
$EnableHWiNFO12hReset = $true  # automatic restart before the 12h limit
$HWiNFOMaxRuntimeMin  = 690   # restart after X minutes (690 = 11.5h)
$EndpointUnhealthyCyclesBeforeRestart = 3   # this many cycles without data, then restart despite live processes
```

### What the watchdog does

Every 60 seconds (configurable) the watchdog checks:

| Check | Action on failure |
| --- | --- |
| HWiNFO64 process gone | Automatic restart + wait 15s |
| RemoteHWInfo process gone | Automatic restart + wait 5s |
| fipha process gone (only with `$EnableFipha`) | Restart, short check only (does not block the loop for long) |
| Processes alive but endpoint returns no data | After 3 cycles in a row: hard restart of HWiNFO64 + RemoteHWInfo |
| HWiNFO runtime > 11.5h | Stop both processes → restart HWiNFO → restart RemoteHWInfo (**deferred** while a stage 2/3 timer or the data-loss fail-safe is running) |
| Endpoint offline | Immediate watchdog check (skip the normal interval) |

The same 60s cycle also triggers the update check (internally throttled to `$UpdateCheckIntervalHours`), see above.

**Limit:** a restart step blocks the polling loop for the length of its waits (HWiNFO 15 s + RemoteHWInfo 5 s, about 25-30 s together for the 12h reset). That almost always coincides with the time HWiNFO delivers no data anyway because it is restarting. A running stage 2/3 timer is not paused, only its evaluation is delayed by at most that time. The 12h reset itself is deferred while a timer is running.

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
4. Compare `labelOriginal` in the JSON with `SensorMatch` in the script

Faster: on its first poll the script writes a **self-test** to the log (see [Logging](#logging)) showing which reading each sensor resolved to. A WARN line `NOT resolved by the live lookup` means label, index or unit does not match.

`Get-SensorDump.ps1` collects every sensor with its unit (including the Unicode code points of the unit) and min/avg/max over 120 s into one file, see [Contributing sensor data](#contributing-sensor-data).

**Unit filter:** for the monitored temperature sensors (CPU, GPU, hotspot, memory junction) a reading is only used if its unit looks like a temperature (`°C`, `C`, `deg C`; up to three characters before the `C`, so a degree sign mangled by an encoding mix-up still passes). Watts, volts, RPM, percent and the like are never taken as a temperature, even if the label matches. Example: `CPU Package` must not fall through to `CPU Package Power`.

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

### "SensorMatch ... only matched readings whose unit is not a temperature"

The unit filter rejected every reading for this label because none has a temperature unit. Check what HWiNFO delivers for the sensor (`Get-SensorDump.ps1` shows the unit with its code points). A temperature unit that is wrongly rejected, please report as an issue. Until then the sensor counts as missing (alert after about 15 s, with the fail-safe a shutdown after 7 min).

### ThermalGuard shut the PC down without overheating

Search the log for `Data-loss fail-safe`. The fail-safe shuts down when the script had no valid CPU/GPU value for 7 minutes (HWiNFO gone, label no longer matches after a hardware swap, Shared Memory off). Fix the cause, or turn the fail-safe off with `$EnableDataLossFailsafe = $false`.

### An update was not staged or installed

Search the log for `Update install`. Common reasons: no SHA-256 on the release (`$UpdateRequireHash`), hash mismatch, syntax error, or `HWiNFO-ThermalGuard.failed-vX.Y.txt` exists (this version already failed once on your machine: delete the file to allow it again). With `$EnableAutoInstall`, an update without a verified hash is never installed automatically.

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
Task "HWiNFO Thermal Guard" (logon + every 5 min)   or   Start-HWiNFO-Remote.vbs
    │
    └── Start-HWiNFO-Remote.bat      (quick check, PowerShell detection, unblock)
            │
            └── HWiNFO-ThermalGuard.ps1      (the only supervisor)
                    │
                    ├── set Shared Memory registry key
                    ├── software check: HWiNFO64, RemoteHWInfo, BurntToast, (fipha), ntfy, firewall rule
                    │       ├── find HWiNFO64 → winget install
                    │       └── find RemoteHWInfo → GitHub ZIP
                    ├── watchdog every 60s
                    │       ├── HWiNFO64 / RemoteHWInfo / fipha alive? → restart if down
                    │       ├── endpoint delivering data? → restart after 3 cycles
                    │       ├── HWiNFO > 11.5h? → 12h reset (deferred during stage 2/3)
                    │       └── update check (throttled) → optional download + staging
                    ├── polling loop every 5s
                    │       ├── CPU / GPU / hotspot / memory junction / fans: warn (digest), crit (immediate)
                    │       ├── stage 1: toast + ntfy → stage 2: kill processes → stage 3: shutdown.exe
                    │       ├── data-loss fail-safe: blind → stage 2 → stage 3
                    │       ├── all-temps report + perf-limit flags → info digest
                    │       └── health marker in the log (for the update installer)
                    │
                    └── log → %USERPROFILE%\HWiNFO-ThermalGuard\

Approve-ThermalGuardUpdate.ps1 ──► HWiNFO-ThermalGuard.ps1 -InstallPendingUpdate   (separate process:
                                   verify → back up → swap → health check → roll back if needed)
Get-SensorDump.ps1             ──► read-only, writes ThermalGuard-SensorDump.txt
```

---

## Limitations

- **HWiNFO Free 12h limit** is handled automatically: the watchdog restarts HWiNFO + RemoteHWInfo before it expires (default: after 11.5h). Can be turned off with `$EnableHWiNFO12hReset = $false`. HWiNFO Pro has no limit.
- **RemoteHWInfo watchdog** detects crashes and restarts the process automatically. On an endpoint outage an immediate watchdog check is forced.
- **Restart steps briefly block polling** (see [watchdog](#what-the-watchdog-does)). That almost only happens while HWiNFO delivers no data anyway.
- **GPU Fan 2** (NVIDIA, where present) is only monitored after it has been seen above 0 RPM once in this run. So a phantom sensor at 0 RPM on a card without a real second fan can never trigger stage 2/3. A fan that is already dead at startup is therefore not detected. If `GPU Fan2` does not exist, there is no alert.
- **A critical sensor that goes dark:** if a sensor's stage 2/3 timer is already running and it then returns no value (or an implausible one), or the whole endpoint goes down, it is presumed to still be critical and keeps escalating. The timer does not freeze. If the hardware really has cooled down in the meantime, the value comes back and the timer is reset as usual.
- **Time jumps:** if the main loop did not run for longer than `$LoopGapResetSec` (180 s), e.g. standby/resume or a frozen process, the stage 2/3 timers and the fail-safe counter are reset instead of counting time nobody measured.
- **Errors in side functions** (watchdog, reports, the evaluation of a single sensor) are contained and logged at most once per 10 minutes per subsystem (`Subsystem '...' threw`). They no longer end the monitoring. A sensor whose evaluation throws counts as invalid and is treated as "blind" by the fail-safe.
- **Stage 3 starts the shutdown before the alert:** `shutdown.exe /s /f /t 10` (`$EmergencyShutdownDelaySec`), then the toast and ntfy go out. A hanging notification path can no longer delay the emergency stop; in exchange the message can be cut off in the last seconds.
- **Crit hysteresis:** a running stage 2/3 timer is only reset once the temperature has fallen `$CritResetHysteresisC` (2 °C) **below** the Crit threshold. A value hovering at the threshold therefore reaches stage 3 instead of restarting the timer on every short dip below Crit.
- **One instance:** the guard runs only once (named mutex `Global\HWiNFO-ThermalGuard-Instance`). A second real instance exits with a warning in the log. `-DryRun`/`-SimulateTemp` and the update installer are exempt.
- **The data-loss fail-safe** can cause an unnecessary shutdown if the sensor connection is down for more than 7 minutes (see [fail-safe](#data-loss-fail-safe)). In exchange you are no longer flying blind.
- **The update hash** does not protect against a compromised repo, see [update safety](#update-safety).
- **The ntfy password** is in plain text in the script (see [ntfy](#setting-up-ntfy)).
- **12V-2x6 pin monitoring** is not natively available through software telemetry on the ASUS Prime 5070 Ti (Power Detector+ only on ROG Astral/Matrix).
- **Toast in fullscreen** is suppressed by Windows. ntfy is the safeguard.
- **Auto-download** needs internet access on first start. Works offline afterwards.

---

## Contributing sensor data

Intel CPUs and Intel Arc GPUs are currently missing because the exact
HWiNFO sensor labels need to be confirmed on real hardware instead of
guessed. If you have one of these, you can help in 2-3 minutes:
[open the issue form](../../issues/new?template=report.yml), run
`Get-SensorDump.ps1` (samples for 120s, ideally with some load/a game
running partway through), and paste the contents of the file it creates, `%USERPROFILE%\HWiNFO-ThermalGuard\ThermalGuard-SensorDump.txt` (read it first: it contains hardware model names, but no user or computer name).

`Get-SensorDump.ps1` expects HWiNFO64 + RemoteHWInfo to already be running
(start `HWiNFO-ThermalGuard.ps1` or the `.bat` launcher first and leave it
running) - if RemoteHWInfo isn't running, the script now fails fast with a
clear message instead of silently retrying for 120 seconds.

---

## License

Free to use. No warranty - thermal protection is ultimately down to the hardware.
