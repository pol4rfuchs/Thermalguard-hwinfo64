#requires -Version 5.1
# ============================================================================
# HWiNFO Thermal Guard
# Single supervisor: this script is the ONLY process manager for
# HWiNFO64, RemoteHWInfo and fipha. The autostart .bat only launches THIS
# script; it does not start or check those three processes itself.
#
# This file is pure ASCII on purpose (no em-dash, no smart quotes, no
# non-ASCII characters anywhere, including inside strings and comments).
# Windows PowerShell 5.1 on a non-UTF8 system codepage can misread a
# BOM-less UTF-8 file and silently corrupt typographic punctuation inside
# string literals, which previously caused parser failures. The file is
# additionally saved with a UTF-8 byte-order-mark (BOM) as a second,
# independent safeguard against the same class of bug.
# ============================================================================

# --- VERSION ---------------------------------------------------------------
# Single source of truth for the version number, used in the startup log
# line below. There was a stale "v2.0" hardcoded in two separate places
# after an abandoned v2.0 attempt was reverted - this variable exists so
# that never happens silently again. Bump this and nowhere else.
$ScriptVersion = "1.42"

# === USER CONFIGURATION ======================================================

# --- PATHS (OPTIONAL OVERRIDE) ------------------------------------------------
# Leave empty to auto-scan a fixed allowlist of folders (see Find-Executable).
# Set explicitly if your installation lives outside that allowlist, e.g. on
# the Desktop or in a Downloads folder - those are intentionally NOT scanned
# automatically any more (security hardening, see report finding #19).
$HWiNFO_Path       = "C:\Users\Wuest3nFuchs\Desktop\HWInfo64\HWInfo64.exe"
$RemoteHWInfo_Path = "C:\Tools\RemoteHWInfo_v0.5\remotehwinfo.exe"
$Fipha_Path        = "C:\Tools\fip-ha-0.0.2.0\fipha.exe"

# --- GPU PROFILE --------------------------------------------------------------
# "AUTO"   -> auto-detect NVIDIA or AMD
# "NVIDIA" -> manual override
# "AMD"    -> manual override
$GPUProfile = "AUTO"

# --- TOGGLES -------------------------------------------------------------------
$EnableCPU   = $true
$EnableGPU   = $true
$EnableNtfy  = $false
$EnableFipha = $true

# --- ntfy ----------------------------------------------------------------------
$NTFY_URL   = "https://REDACTED"
$NTFY_TOPIC = "ha-system"

# --- ALL-TEMPS OVERVIEW REPORT ---------------------------------------------------
# Independent of the 4 monitored sensors above (CPU/GPU/Hotspot/Fan): this scans
# EVERY temperature reading HWiNFO reports (all cores, all VRM/chipset/SSD/etc.
# sensors it exposes) and sends one summary listing everything currently over
# $AllTempsThreshold. Sent once at script start, then again only when the SET of
# sensors over the threshold changes (something new crosses over, or drops back
# under) - not on every poll, to avoid spam.
$EnableAllTempsReport = $true
$AllTempsThreshold    = 60
# HWiNFO/RemoteHWInfo's JSON "unit" field for temperature readings. Confirmed via
# the self-test log line (search "unit=" in thermalguard.log after first run,
# Write-Log around the sensor self-test). Adjust this regex if your log shows a
# different string.
# HWiNFO/RemoteHWInfo's JSON "unit" field for temperature readings. Confirmed
# live against this system's json.json: it is literally the degree sign + C
# (e.g. "43 C" reading has unit "?C"). Built from a char code below instead of
# a literal non-ASCII character, to keep this file pure ASCII per the header
# note (avoids the BOM/codepage corruption class of bug already fixed once).
$script:DegreeSign   = [char]0x00B0
$TempUnitPattern     = "(?i)^\s*($($script:DegreeSign)c|deg\s*c|c)\s*`$"

# --- THRESHOLDS ------------------------------------------------------------
# Hardware basis: AMD Ryzen 7 5800X3D has a Tjmax (hardware throttle point)
# of 90 C. The previous default Crit value of 91 C was ABOVE that point,
# meaning the hardware would already be throttling itself before this
# script's own "critical" stage ever triggered (report finding, hardware
# limits section). Values below leave a safety margin under each chip's
# real throttle point instead of guessing a round number.
$CPU_WarnTemp    = 80    # AMD 5800X3D Tjmax is 90 C; this leaves 10 C margin
$CPU_CritTemp    = 87    # 3 C margin under Tjmax
$GPU_WarnTemp    = 80    # NVIDIA official Maximum GPU Temperature for RTX 5070 Ti = 88 C
$GPU_CritTemp    = 86    # 2 C margin under NVIDIA's published 88 C spec (verified, not assumed)
$GPU_HotspotWarn = 95    # AMD hotspot only, typical AMD GPU Tjmax ~110 C
$GPU_HotspotCrit = 105
$GPU_FanWarnRPM  = 300
$GPU_FanCritRPM  = 0
$GPULoadThreshold = 50
# GDDR6X/7 memory junction temp. Micron rates GDDR6X junction around 110 C max;
# this leaves margin under that similar to the CPU/GPU die margins above.
$GPU_MemJunctionWarn = 90
$GPU_MemJunctionCrit = 100

# --- PERFORMANCE LIMIT FLAGS (NVIDIA) -------------------------------------------
# HWiNFO exposes these as separate Yes/No readings per GPU. Alerted on
# edge-change (0->1 and 1->0), not every poll, since they are already
# instantaneous flags, not thresholds. "Utilization" is deliberately excluded:
# it reads 1 whenever the GPU just isn't maxed out, which is normal idle/light
# load behavior, not a throttle. "SLI GPUBoost Sync" excluded, single-GPU only.
$EnablePerfLimitAlerts = $true
$PerfLimitFlagsToWatch = @(
    "Performance Limit - Power"
    "Performance Limit - Thermal"
    "Performance Limit - Reliability Voltage"
    "Performance Limit - Max Operating Voltage"
)

# --- TIMING --------------------------------------------------------------------
$PollInterval = 5
$Stage2Delay  = 30
$Stage3Delay  = 90

# --- KILL LIST (Stage 2) --------------------------------------------------------
$KillProcesses = @(
    "TslGame"
    "Stalker2-Win64-Shipping"
    "obs64"
    "chrome"
    "firefox"
    "floorp"
)

# --- ENDPOINT --------------------------------------------------------------------
$HWiNFO_URL = "http://localhost:60000/json.json"

# --- INSTALL TARGET FOLDER (allowlist root for auto-download) -------------------
$ToolsDir = "C:\Tools"

# --- WATCHDOG --------------------------------------------------------------------
$EnableWatchdog        = $true
$WatchdogIntervalSec   = 60
$EnableHWiNFO12hReset  = $true
$HWiNFOMaxRuntimeMin   = 690
# How many consecutive watchdog cycles the HTTP endpoint may be unreachable
# or return no readings before the watchdog force-restarts HWiNFO64 and
# RemoteHWInfo even though their PROCESSES are still alive. This fixes
# report finding #8 ("watchdog checks process existence, not data health").
$EndpointUnhealthyCyclesBeforeRestart = 3

# --- FIREWALL HARDENING -----------------------------------------------------------
# RemoteHWInfo is documented upstream as a generic HTTP/JSON server and does
# not expose a documented loopback-only bind flag in this version. As a
# script-level mitigation (report finding #22) this creates an inbound block
# rule for the RemoteHWInfo port from any non-loopback source. Requires
# admin rights, which this script already needs for shutdown.exe.
$EnableFirewallHardening = $true
$RemoteHWInfoPort        = 60000

# === INTERNAL CONFIGURATION (do not edit) ====================================

$MissingSensorAlertAfterPolls      = 3
$MissingSensorAlertIntervalMinutes = 30
$EndpointAlertIntervalMinutes      = 15
$LogDir       = "$env:USERPROFILE\HWiNFO-ThermalGuard"
$LogFile      = Join-Path $LogDir "thermalguard.log"
$MaxLogSizeMB = 10

# === LOGGING (must be defined before anything else can call it) =============

$script:LoggedSensorMatchWarnings = @{}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length / 1MB) -gt $MaxLogSizeMB) {
        $backup = $LogFile -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Move-Item $LogFile $backup -Force
    }
}

# === DEPENDENCY SCAN AND AUTO-DOWNLOAD =======================================
# Report findings #19/#11: Desktop and Downloads are intentionally NOT in this
# list any more. If your install lives there, set the *_Path override above
# or move the install into one of these allowlisted locations.

function Find-Executable {
    param([string]$Name, [string[]]$SearchPaths, [int]$MinSizeBytes = 5000)

    foreach ($dir in $SearchPaths) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $candidates = Get-ChildItem -Path $dir -Filter $Name -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                      Where-Object {
                          $_.FullName -notmatch '\\WindowsApps\\' -and
                          $_.Length -ge $MinSizeBytes
                      } |
                      Sort-Object Length -Descending
        if ($candidates) {
            return ($candidates | Select-Object -First 1).FullName
        }
    }

    $inPath = Get-Command $Name -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.Source -notmatch '\\WindowsApps\\' -and
                  (Test-Path $_.Source) -and
                  ((Get-Item $_.Source).Length -ge $MinSizeBytes)
              } |
              Select-Object -First 1

    if ($inPath) { return $inPath.Source }
    return $null
}

function Resolve-HWiNFO {
    if ($script:HWiNFO_Path -and (Test-Path $script:HWiNFO_Path)) {
        Write-Log "HWiNFO64        [OK] Override: $($script:HWiNFO_Path)"
        return $script:HWiNFO_Path
    }

    Write-Log "HWiNFO64        Scanning allowlisted folders..."
    $scanPaths = @(
        "$env:ProgramFiles\HWiNFO64"
        "${env:ProgramFiles(x86)}\HWiNFO64"
        "$ToolsDir\HWiNFO64"
        "$ToolsDir"
    )
    $found = Find-Executable -Name "HWiNFO64.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "HWiNFO64        [OK] Found: $found"
        return $found
    }

    Write-Log "HWiNFO64        [MISSING] Attempting install via winget..." "WARN"
    try {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            $result = & winget install REALiX.HWiNFO --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1
            Write-Log "winget output: $($result -join ' ')"
            $found = Find-Executable -Name "HWiNFO64.exe" -SearchPaths $scanPaths
            if ($found) {
                Write-Log "HWiNFO64        [OK] Installed: $found"
                return $found
            }
        }
    } catch {
        Write-Log "winget failed: $_" "WARN"
    }

    Write-Log "HWiNFO64        [ERROR] Could not be located or installed" "ERROR"
    Write-Log "  -> Move your install into $ToolsDir, or set `$HWiNFO_Path manually." "ERROR"
    Write-Log "  -> Manual download: https://www.hwinfo.com/download/" "ERROR"
    return $null
}

function Resolve-RemoteHWInfo {
    if ($script:RemoteHWInfo_Path -and (Test-Path $script:RemoteHWInfo_Path)) {
        Write-Log "RemoteHWInfo    [OK] Override: $($script:RemoteHWInfo_Path)"
        return $script:RemoteHWInfo_Path
    }

    Write-Log "RemoteHWInfo    Scanning allowlisted folders..."
    $scanPaths = @(
        "$ToolsDir\RemoteHWInfo"
        "$ToolsDir"
    )
    $found = Find-Executable -Name "RemoteHWInfo.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "RemoteHWInfo    [OK] Found: $found"
        return $found
    }

    Write-Log "RemoteHWInfo    [MISSING] Downloading..." "WARN"
    try {
        $downloadUrl = "https://github.com/Demion/remotehwinfo/releases/download/v0.5/RemoteHWInfo_v0.5.zip"
        $targetDir   = Join-Path $ToolsDir "RemoteHWInfo"
        $zipFile     = Join-Path $env:TEMP "RemoteHWInfo_v0.5.zip"

        if (-not (Test-Path $ToolsDir))  { New-Item -ItemType Directory -Path $ToolsDir  -Force | Out-Null }
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

        Write-Log "  Download: $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing -TimeoutSec 60

        # Report finding #21: there is no publicly pinned, independently
        # verifiable hash for this release published by the upstream
        # project to check against here. The honest mitigation available
        # without fabricating a false sense of verification is to compute
        # and clearly log the hash of what was actually downloaded, so a
        # human operator can cross-check it against the GitHub release
        # page or VirusTotal before trusting it on a sensitive machine.
        $hash = (Get-FileHash -Path $zipFile -Algorithm SHA256).Hash
        Write-Log "  Downloaded file SHA-256: $hash" "WARN"
        Write-Log "  This hash is NOT verified against a pinned value. Cross-check it manually at https://github.com/Demion/remotehwinfo/releases/tag/v0.5 before trusting this binary." "WARN"

        Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue

        $found = Find-Executable -Name "RemoteHWInfo.exe" -SearchPaths @($targetDir)
        if ($found) {
            Write-Log "RemoteHWInfo    [OK] Installed: $found"
            return $found
        }
    } catch {
        Write-Log "Download failed: $_" "ERROR"
    }

    Write-Log "RemoteHWInfo    [ERROR] Could not be located or installed" "ERROR"
    Write-Log "  -> Manual download: https://github.com/Demion/remotehwinfo/releases/tag/v0.5" "ERROR"
    return $null
}

function Resolve-Fipha {
    if (-not $EnableFipha) {
        Write-Log "fipha           [OFF]"
        return $null
    }

    if ($script:Fipha_Path -and (Test-Path $script:Fipha_Path)) {
        Write-Log "fipha           [OK] Override: $($script:Fipha_Path)"
        return $script:Fipha_Path
    }

    Write-Log "fipha           Scanning allowlisted folders..."
    $scanPaths = @(
        "$ToolsDir\fipha"
        "$ToolsDir"
    )
    $found = Find-Executable -Name "fipha.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "fipha           [OK] Found: $found"
        return $found
    }

    Write-Log "fipha           [MISSING] Not found" "WARN"
    Write-Log "  -> Move your install into $ToolsDir, or set `$Fipha_Path manually." "WARN"
    Write-Log "  -> Manual download: https://github.com/mhwlng/fipha/releases" "WARN"
    return $null
}

function Resolve-BurntToast {
    # Report finding #7: a missing notification module must never be allowed
    # to take down the actual temperature protection loop. This function
    # therefore only ever returns informational state; its result is not
    # used to fail Test-Requirements any more.
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Write-Log "BurntToast      [MISSING] Attempting install..." "WARN"
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Install-Module BurntToast -Force -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
            Write-Log "BurntToast      [OK] Installed"
        } catch {
            Write-Log "BurntToast      [WARN] Install failed: $_" "WARN"
            Write-Log "  Notifications will be degraded. Manual install: Install-Module BurntToast -Force -Scope CurrentUser" "WARN"
            return $false
        }
    } else {
        Write-Log "BurntToast      [OK]"
    }
    Import-Module BurntToast -ErrorAction SilentlyContinue
    return $true
}

# === FIREWALL HARDENING ======================================================
# Report finding #22.

function Set-FirewallHardening {
    if (-not $EnableFirewallHardening) { return }
    try {
        $ruleName = "HWiNFO-ThermalGuard-Block-NonLocal-$RemoteHWInfoPort"
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Action Block -Protocol TCP -LocalPort $RemoteHWInfoPort `
                -RemoteAddress Any `
                -ErrorAction Stop | Out-Null
            Write-Log "Firewall        [OK] Inbound block rule created for port $RemoteHWInfoPort (non-loopback)"
        } else {
            Write-Log "Firewall        [OK] Block rule already present"
        }
    } catch {
        Write-Log "Firewall        [WARN] Could not create block rule: $_" "WARN"
        Write-Log "  RemoteHWInfo port $RemoteHWInfoPort may be reachable from other devices on this network." "WARN"
    }
}

# === HARDWARE DETECTION ======================================================
# Report finding #14: on hybrid systems the first WMI match is not
# necessarily the right one. All matches are now collected and a discrete
# GPU (model number present) is preferred over a generic/integrated name.

function Detect-GPUProfile {
    Write-Log "GPU Detection   Starting..."

    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft|Remote|Virtual' }

        $nvidiaMatch = $null
        $amdMatch    = $null
        foreach ($gpu in $gpus) {
            $name = $gpu.Name.ToUpper()
            Write-Log "GPU Detection   Found: $($gpu.Name)"
            # Discrete-looking names (RTX/GTX/RX followed by a digit) are
            # preferred over generic iGPU names like "Radeon(TM) Graphics".
            if ($name -match 'NVIDIA|GEFORCE|RTX|GTX|QUADRO') {
                if (-not $nvidiaMatch -or $name -match '(RTX|GTX)\s*\d') { $nvidiaMatch = $gpu }
            }
            if ($name -match 'AMD|RADEON|RX\s') {
                if (-not $amdMatch -or $name -match 'RX\s*\d') { $amdMatch = $gpu }
            }
        }

        if ($nvidiaMatch) {
            Write-Log "GPU Detection   [OK] NVIDIA selected: $($nvidiaMatch.Name)"
            $script:DetectedGPUName = $nvidiaMatch.Name
            return "NVIDIA"
        }
        if ($amdMatch) {
            Write-Log "GPU Detection   [OK] AMD selected: $($amdMatch.Name)"
            $script:DetectedGPUName = $amdMatch.Name
            return "AMD"
        }
    } catch {
        Write-Log "GPU Detection   WMI failed: $_" "WARN"
    }

    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($r.hwinfo -and $r.hwinfo.sensors) {
            foreach ($sensor in $r.hwinfo.sensors) {
                $sName = $sensor.sensorNameOriginal.ToUpper()
                if ($sName -match 'NVIDIA|GEFORCE|RTX|GTX') {
                    Write-Log "GPU Detection   [OK] NVIDIA selected via HWiNFO fallback"
                    $script:DetectedGPUName = $sensor.sensorNameOriginal
                    $script:DetectedGPUSensorIndex = $sensor.entryIndex
                    return "NVIDIA"
                }
                if ($sName -match 'AMD|RADEON|RX\s') {
                    Write-Log "GPU Detection   [OK] AMD selected via HWiNFO fallback"
                    $script:DetectedGPUName = $sensor.sensorNameOriginal
                    $script:DetectedGPUSensorIndex = $sensor.entryIndex
                    return "AMD"
                }
            }
        }
    } catch {
        # endpoint not up yet at this point in startup, this is expected
    }

    Write-Log "GPU Detection   [ERROR] No supported GPU detected" "ERROR"
    Write-Log "  -> Set `$GPUProfile manually to 'NVIDIA' or 'AMD'" "ERROR"
    return $null
}

if ($GPUProfile -eq "AUTO") {
    $detected = Detect-GPUProfile
    if ($detected) {
        $GPUProfile = $detected
    } else {
        Write-Host "ERROR: GPU could not be detected. Set `$GPUProfile manually."
        exit 1
    }
}

# === GPU PROFILES =============================================================

$GPUProfiles = @{
    "NVIDIA" = @{
        TempMatch        = "GPU Temperature"
        TempWarn         = $GPU_WarnTemp
        TempCrit         = $GPU_CritTemp
        HotspotMatch     = $null
        FanMatch         = "GPU Fan1"
        FanWarn          = $GPU_FanWarnRPM
        FanCrit          = $GPU_FanCritRPM
        LoadMatch        = "GPU Core Load"
        # Confirmed live on RTX 5070 Ti (sensorIndex 10, unit degree-C).
        MemJunctionMatch = "GPU Memory Junction Temperature"
        MemJunctionWarn  = $GPU_MemJunctionWarn
        MemJunctionCrit  = $GPU_MemJunctionCrit
        # Board power draw, confirmed live (unit W). Used only as an
        # informational line in the all-temps report, not a threshold alert -
        # the Performance Limit - Power flag already fires exactly when the
        # power limit is actually restricting the GPU.
        PowerMatch       = "GPU Power"
    }
    "AMD" = @{
        TempMatch        = "GPU Temperature"
        TempWarn         = $GPU_WarnTemp
        TempCrit         = $GPU_CritTemp
        HotspotMatch     = "GPU Hot Spot Temperature"
        HotspotWarn      = $GPU_HotspotWarn
        HotspotCrit      = $GPU_HotspotCrit
        FanMatch         = "GPU Fan"
        FanWarn          = $GPU_FanWarnRPM
        FanCrit          = $GPU_FanCritRPM
        LoadMatch        = "GPU Utilization"
        # Not confirmed on real AMD hardware yet (labels above were, on this
        # system's NVIDIA card) - leave off until verified via the same
        # json.json dump on an AMD GPU, rather than guessing a label.
        MemJunctionMatch = $null
        MemJunctionWarn  = $GPU_MemJunctionWarn
        MemJunctionCrit  = $GPU_MemJunctionCrit
        PowerMatch       = $null
    }
}

if (-not $GPUProfiles.ContainsKey($GPUProfile)) {
    Write-Host "ERROR: Unknown GPU profile '$GPUProfile'. Allowed: AUTO, NVIDIA, AMD"
    exit 1
}

# === SENSOR LIST ===============================================================
# Report finding #13: sensor matching now also records a preferred
# sensorIndex (the GPU's own device entry, captured during detection) so
# GPU-group sensors can disambiguate against other devices that happen to
# share a label, instead of relying on label text alone.

$Sensors = @(
    @{
        Name          = "CPU Tctl/Tdie"
        SensorMatch   = "CPU (Tctl/Tdie)"
        WarnThreshold = $CPU_WarnTemp
        CritThreshold = $CPU_CritTemp
        Type          = "temp"
        Group         = "CPU"
        PreferredSensorIndex = $null
    }
)

if ($EnableGPU) {
    $p = $GPUProfiles[$GPUProfile]

    $Sensors += @{
        Name = "GPU Temperature"; SensorMatch = $p.TempMatch
        WarnThreshold = $p.TempWarn; CritThreshold = $p.TempCrit
        Type = "temp"; Group = "GPU"
        PreferredSensorIndex = $script:DetectedGPUSensorIndex
    }
    if ($p.HotspotMatch) {
        $Sensors += @{
            Name = "GPU Hotspot"; SensorMatch = $p.HotspotMatch
            WarnThreshold = $p.HotspotWarn; CritThreshold = $p.HotspotCrit
            Type = "temp"; Group = "GPU"
            PreferredSensorIndex = $script:DetectedGPUSensorIndex
        }
    }
    if ($p.MemJunctionMatch) {
        $Sensors += @{
            Name = "GPU Memory Junction"; SensorMatch = $p.MemJunctionMatch
            WarnThreshold = $p.MemJunctionWarn; CritThreshold = $p.MemJunctionCrit
            Type = "temp"; Group = "GPU"
            PreferredSensorIndex = $script:DetectedGPUSensorIndex
        }
    }
    $Sensors += @{
        Name = "GPU Fan"; SensorMatch = $p.FanMatch
        WarnThreshold = $p.FanWarn; CritThreshold = $p.FanCrit
        Type = "fan"; Group = "GPU"
        PreferredSensorIndex = $script:DetectedGPUSensorIndex
    }
}

# === SOFTWARE CHECK ===========================================================

function Test-Requirements {
    Write-Log "=== Software Check ==="
    Write-Log "PowerShell      [OK] v$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $ok = $true

    # BurntToast failure is informational only (report finding #7).
    Resolve-BurntToast | Out-Null

    $script:ResolvedHWiNFO = Resolve-HWiNFO
    if (-not $script:ResolvedHWiNFO) { $ok = $false }

    $script:ResolvedRemoteHWInfo = Resolve-RemoteHWInfo
    if (-not $script:ResolvedRemoteHWInfo) { $ok = $false }

    $hw = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
    if ($hw) {
        Write-Log "HWiNFO64 Proc   [OK] PID $($hw.Id), started $($hw.StartTime)"
    } else {
        if ($script:ResolvedHWiNFO) {
            Write-Log "HWiNFO64 Proc   [STARTING]..." "WARN"
            Start-Process $script:ResolvedHWiNFO
            Start-Sleep -Seconds 15
            $hw = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            if ($hw) {
                Write-Log "HWiNFO64 Proc   [OK] PID $($hw.Id)"
            } else {
                Write-Log "HWiNFO64 Proc   [ERROR] Could not be started" "ERROR"
                $ok = $false
            }
        } else {
            Write-Log "HWiNFO64 Proc   [ERROR] Not installed" "ERROR"
            $ok = $false
        }
    }
    if ($hw) { $script:HWiNFOStartTime = $hw.StartTime }

    $rh = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
    if ($rh) {
        Write-Log "RemoteHWInfo Proc [OK] PID $($rh.Id)"
    } else {
        if ($script:ResolvedRemoteHWInfo) {
            Write-Log "RemoteHWInfo Proc [STARTING]..." "WARN"
            Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
            Start-Sleep -Seconds 5
            $rh = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
            if ($rh) {
                Write-Log "RemoteHWInfo Proc [OK] PID $($rh.Id)"
            } else {
                Write-Log "RemoteHWInfo Proc [ERROR] Could not be started" "ERROR"
                $ok = $false
            }
        } else {
            Write-Log "RemoteHWInfo Proc [ERROR] Not installed" "ERROR"
            $ok = $false
        }
    }

    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5
        if ($r.hwinfo -and $r.hwinfo.readings) {
            Write-Log "HTTP Endpoint   [OK] $HWiNFO_URL ($($r.hwinfo.readingCount) readings)"
        } else {
            Write-Log "HTTP Endpoint   [ERROR] Invalid JSON structure" "ERROR"
            Write-Log "  Hint: HWiNFO may not be in Sensors-only mode yet (report finding #17)." "WARN"
            $ok = $false
        }
    } catch {
        Write-Log "HTTP Endpoint   [ERROR] Not reachable: $HWiNFO_URL" "ERROR"
        Write-Log "  Hint: confirm HWiNFO Sensors-only mode and Shared Memory Support are both enabled." "WARN"
        $ok = $false
    }

    if ($EnableNtfy) {
        try {
            Invoke-RestMethod -Uri "$NTFY_URL/$NTFY_TOPIC" -Method Post -Body "ThermalGuard started" `
                -Headers @{ "Title" = "ThermalGuard started"; "Tags" = "white_check_mark" } `
                -TimeoutSec 5 | Out-Null
            Write-Log "ntfy            [OK] $NTFY_URL/$NTFY_TOPIC"
        } catch {
            Write-Log "ntfy            [WARN] Not reachable" "WARN"
        }
    } else {
        Write-Log "ntfy            [OFF]"
    }

    if ($EnableFipha) {
        $script:ResolvedFipha = Resolve-Fipha
        if ($script:ResolvedFipha) {
            $fp = Get-Process fipha -ErrorAction SilentlyContinue
            if ($fp) {
                Write-Log "fipha Proc      [OK] PID $($fp.Id)"
            } else {
                Write-Log "fipha Proc      [STARTING]..." "WARN"
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                try {
                    $proc = Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    $fp = Get-Process fipha -ErrorAction SilentlyContinue
                    $stillAlive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    if ($fp) {
                        Write-Log "fipha Proc      [OK] PID $($fp.Id)"
                    } elseif ($stillAlive) {
                        Write-Log "fipha Proc      [WARN] Alive (PID $($proc.Id)) but process name is '$($stillAlive.ProcessName)', not 'fipha'" "WARN"
                    } else {
                        Write-Log "fipha Proc      [WARN] Exited immediately after launch (check its own config/log)" "WARN"
                    }
                } catch {
                    Write-Log "fipha Proc      [WARN] Start-Process threw: $_" "WARN"
                }
            }
        }
        # fipha failure is non-fatal: it is an optional MQTT bridge, not
        # part of the thermal protection loop itself.
    }

    Set-FirewallHardening

    Write-Log "=== Software Check complete ==="
    return $ok
}

# === NOTIFICATIONS ============================================================

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            New-BurntToastNotification -Text $Title, $Body -Sound "Alarm" -UniqueIdentifier "ThermalGuard"
        }
    } catch {
        Write-Log "Toast failed: $_" "WARN"
    }
}

function Send-Ntfy {
    param([string]$Title, [string]$Body, [string]$Priority = "high")
    if (-not $EnableNtfy) { return }
    try {
        Invoke-RestMethod -Uri "$NTFY_URL/$NTFY_TOPIC" -Method Post -Body $Body `
            -Headers @{ "Title" = $Title; "Priority" = $Priority; "Tags" = "warning,thermometer" } `
            -TimeoutSec 5 | Out-Null
        Write-Log "ntfy sent: $Title"
    } catch {
        Write-Log "ntfy failed: $_" "WARN"
    }
}

$script:LastOverThresholdKey = $null

function Get-AllTempsOverThreshold {
    param($SensorData, [double]$Threshold)

    $seen   = @{}
    $result = @()
    foreach ($reading in $SensorData.readings) {
        if ([string]$reading.unit -notmatch $TempUnitPattern) { continue }
        $val = $null
        if (-not [double]::TryParse([string]$reading.value, [ref]$val)) { continue }
        if ($val -lt $Threshold) { continue }

        # Same dedup key as elsewhere: sensorIndex+readingId identifies one
        # physical reading, HWiNFO/RemoteHWInfo can list it twice.
        $dedupKey = "$($reading.sensorIndex)|$($reading.readingId)"
        if ($seen.ContainsKey($dedupKey)) { continue }
        $seen[$dedupKey] = $true

        $label = if ($reading.labelUser) { $reading.labelUser } else { $reading.labelOriginal }
        $result += [PSCustomObject]@{
            Label = $label
            Value = $val
        }
    }
    return $result | Sort-Object Label
}

function Get-CurrentGPUPowerLine {
    param($SensorData)

    if (-not $EnableGPU) { return $null }
    $powerMatch = $GPUProfiles[$GPUProfile].PowerMatch
    if (-not $powerMatch) { return $null }

    $reading = $SensorData.readings | Where-Object {
        $_.labelOriginal -eq $powerMatch -and $_.sensorIndex -eq $script:DetectedGPUSensorIndex
    } | Select-Object -First 1
    if (-not $reading) { return $null }

    return "GPU Power: $($reading.value) W"
}

function Invoke-AllTempsReportCheck {
    param($SensorData)

    if (-not $EnableAllTempsReport) { return }

    $overList = Get-AllTempsOverThreshold -SensorData $SensorData -Threshold $AllTempsThreshold
    $currentKey = ($overList | ForEach-Object { "$($_.Label)=$($_.Value)" }) -join ';'

    if ($currentKey -eq $script:LastOverThresholdKey) { return }
    $script:LastOverThresholdKey = $currentKey

    if ($overList.Count -eq 0) {
        Write-Log "All-temps report: back under $AllTempsThreshold C on all sensors"
        Send-Alert -Title "Temps back under $AllTempsThreshold C" -Body "No sensor above threshold anymore." -Priority "default"
        return
    }

    $lines = $overList | ForEach-Object { "$($_.Label): $($_.Value) C" }
    $powerLine = Get-CurrentGPUPowerLine -SensorData $SensorData
    if ($powerLine) { $lines += $powerLine }
    $body  = $lines -join "`n"
    Write-Log "All-temps report: $($overList.Count) sensor(s) over $AllTempsThreshold C -> $($lines -join ' | ')"
    Send-Alert -Title "Temps over $AllTempsThreshold C ($($overList.Count))" -Body $body -Priority "default"
}

$script:PerfLimitLastState = @{}

function Invoke-PerfLimitCheck {
    param($SensorData)

    if (-not $EnablePerfLimitAlerts) { return }
    if (-not $EnableGPU) { return }

    foreach ($flagName in $PerfLimitFlagsToWatch) {
        $reading = $SensorData.readings | Where-Object {
            $_.labelOriginal -eq $flagName -and $_.sensorIndex -eq $script:DetectedGPUSensorIndex
        } | Select-Object -First 1
        if (-not $reading) { continue }

        $isActive = ([double]$reading.value -eq 1)
        $prev = $script:PerfLimitLastState[$flagName]

        # First poll: record the baseline silently, only alert if it starts
        # out already active (real condition, not a false "just changed").
        if ($null -eq $prev) {
            $script:PerfLimitLastState[$flagName] = $isActive
            if (-not $isActive) { continue }
        } elseif ($prev -eq $isActive) {
            continue
        } else {
            $script:PerfLimitLastState[$flagName] = $isActive
        }

        if ($isActive) {
            Write-Log "$flagName ACTIVE (GPU throttling)" "WARN"
            Send-Alert -Title "GPU Throttle: $flagName" -Body "GPU is currently limited by this factor." -Priority "high"
        } else {
            Write-Log "$flagName cleared"
            Send-Alert -Title "$flagName cleared" -Body "GPU no longer limited by this factor." -Priority "default"
        }
    }
}

function Send-Alert {
    param([string]$Title, [string]$Body, [string]$Priority = "high")
    Send-Toast -Title $Title -Body $Body
    Send-Ntfy  -Title $Title -Body $Body -Priority $Priority
}

# === SENSOR READING ===========================================================

function Get-HWiNFOSensors {
    try {
        $response = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5
        return $response.hwinfo
    } catch {
        return $null
    }
}

function Find-SensorValue {
    param($SensorData, [string]$Match, $PreferredSensorIndex = $null, [string]$PreferredUnit = $null)

    $exactMatches   = @()
    $partialMatches = @()
    foreach ($reading in $SensorData.readings) {
        $lo = [string]$reading.labelOriginal
        $lu = [string]$reading.labelUser
        if ($lo -eq $Match -or $lu -eq $Match)            { $exactMatches   += $reading; continue }
        if ($lo -like "*$Match*" -or $lu -like "*$Match*") { $partialMatches += $reading }
    }
    $m = if ($exactMatches.Count -gt 0) { $exactMatches } else { $partialMatches }

    if ($m.Count -gt 1 -and $PreferredSensorIndex) {
        $byIndex = $m | Where-Object { $_.sensorIndex -eq $PreferredSensorIndex }
        if ($byIndex) { $m = $byIndex }
    }

    # Collapse true duplicates: HWiNFO/RemoteHWInfo can list the exact same
    # reading twice (identical sensorIndex + readingId + value). That is a
    # listing artifact, not a real ambiguity between two different sensors,
    # so it must not trigger the "ambiguous match" warning.
    if ($m.Count -gt 1) {
        $deduped = $m | Sort-Object sensorIndex, readingId -Unique
        $m = $deduped
    }

    # Same display label can legitimately belong to two physically different
    # readings (e.g. a fan's RPM value and its PWM duty-cycle percentage
    # both reported under the label "GPU Fan1"). When the caller knows what
    # physical unit it actually wants, filter on that before treating the
    # remainder as a genuine ambiguity.
    if ($m.Count -gt 1 -and $PreferredUnit) {
        $byUnit = $m | Where-Object { [string]$_.unit -eq $PreferredUnit }
        if ($byUnit) { $m = $byUnit }
    }

    if ($m.Count -gt 1 -and -not $script:LoggedSensorMatchWarnings[$Match]) {
        $labels = ($m | Select-Object -First 5 | ForEach-Object { "$($_.labelOriginal) [sensorIndex=$($_.sensorIndex) readingId=$($_.readingId) unit=$($_.unit)]" }) -join ' | '
        Write-Log "Ambiguous SensorMatch '$Match': $labels" "WARN"
        $script:LoggedSensorMatchWarnings[$Match] = $true
    }
    if ($m.Count -eq 0) { return $null }
    try { return [double]$m[0].value } catch { return $null }
}

function Find-GPULoad {
    param($SensorData)
    $loadMatch = $GPUProfiles[$GPUProfile].LoadMatch
    return Find-SensorValue -SensorData $SensorData -Match $loadMatch -PreferredSensorIndex $script:DetectedGPUSensorIndex
}

# === STAGE 2 / STAGE 3 ========================================================

function Invoke-KillProcesses {
    Write-Log "=== STAGE 2: killing processes ===" "CRIT"
    foreach ($proc in $KillProcesses) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Killing: $proc (PID: $($running.Id -join ', '))"
            Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Shutdown {
    Write-Log "=== STAGE 3: EMERGENCY SHUTDOWN ===" "CRIT"
    Send-Alert -Title "EMERGENCY SHUTDOWN" -Body "System is shutting down now." -Priority "urgent"
    Start-Sleep -Seconds 2
    & shutdown.exe /s /f /t 0
}

# === WATCHDOG =================================================================
# Report finding #8: the watchdog now tracks ENDPOINT HEALTH (does the
# server actually return readable sensor data), not just whether the
# process names exist. A process can be alive and hung, or alive with
# Shared Memory disabled, while still showing up in Get-Process.

function Test-EndpointHealthy {
    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5 -ErrorAction Stop
        return ($null -ne $r.hwinfo -and $null -ne $r.hwinfo.readings -and $r.hwinfo.readings.Count -gt 0)
    } catch {
        return $false
    }
}

function Invoke-Watchdog {
    param(
        [ref]$LastWatchdogRun,
        [ref]$UnhealthyCycleCount
    )

    $now = Get-Date
    if ($LastWatchdogRun.Value -and (($now - $LastWatchdogRun.Value).TotalSeconds -lt $WatchdogIntervalSec)) {
        return
    }
    $LastWatchdogRun.Value = $now

    $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
    $rhProc = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
    $endpointOk = Test-EndpointHealthy

    if (-not $hwProc) {
        Write-Log "WATCHDOG: HWiNFO64 process gone, restarting..." "WARN"
        if ($script:ResolvedHWiNFO -and (Test-Path $script:ResolvedHWiNFO)) {
            Start-Process $script:ResolvedHWiNFO
            Start-Sleep -Seconds 15
            $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            if ($hwProc) {
                Write-Log "WATCHDOG: HWiNFO64 restarted (PID $($hwProc.Id))"
                $script:HWiNFOStartTime = $hwProc.StartTime
            } else {
                Write-Log "WATCHDOG: HWiNFO64 restart failed" "ERROR"
                Send-Alert -Title "Watchdog: HWiNFO64 down" -Body "Restart failed" -Priority "urgent"
            }
        }
        $UnhealthyCycleCount.Value = 0
        return
    }

    if ($EnableHWiNFO12hReset -and $script:HWiNFOStartTime) {
        $runtimeMin = ($now - $script:HWiNFOStartTime).TotalMinutes
        if ($runtimeMin -ge $HWiNFOMaxRuntimeMin) {
            Write-Log "WATCHDOG: HWiNFO64 running for $([int]$runtimeMin) min, performing 12h reset..." "WARN"
            Send-Alert -Title "HWiNFO 12h reset" -Body "Automatic restart (free version session limit)" -Priority "default"

            Stop-Process -Name HWiNFO64 -Force -ErrorAction SilentlyContinue
            Stop-Process -Name RemoteHWInfo -Force -ErrorAction SilentlyContinue
            if ($EnableFipha) { Stop-Process -Name fipha -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3

            Start-Process $script:ResolvedHWiNFO
            Start-Sleep -Seconds 15
            if ($script:ResolvedRemoteHWInfo) {
                Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
                Start-Sleep -Seconds 5
            }
            if ($EnableFipha -and $script:ResolvedFipha) {
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir
                Start-Sleep -Seconds 5
            }

            $hwCheck = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            $rhCheck = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
            if ($hwCheck) { $script:HWiNFOStartTime = $hwCheck.StartTime }
            if ($hwCheck -and $rhCheck) {
                Write-Log "WATCHDOG: 12h reset successful"
            } else {
                Write-Log "WATCHDOG: 12h reset incomplete, not all processes confirmed" "ERROR"
                Send-Alert -Title "Watchdog: 12h reset problem" -Body "HWiNFO or RemoteHWInfo missing after reset" -Priority "urgent"
            }
            $UnhealthyCycleCount.Value = 0
            return
        }
    }

    if (-not $rhProc) {
        Write-Log "WATCHDOG: RemoteHWInfo process gone, restarting..." "WARN"
        if ($script:ResolvedRemoteHWInfo -and (Test-Path $script:ResolvedRemoteHWInfo)) {
            Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
            Start-Sleep -Seconds 5
            $rhProc = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
            if ($rhProc) {
                Write-Log "WATCHDOG: RemoteHWInfo restarted (PID $($rhProc.Id))"
            } else {
                Write-Log "WATCHDOG: RemoteHWInfo restart failed" "ERROR"
                Send-Alert -Title "Watchdog: RemoteHWInfo down" -Body "Restart failed" -Priority "urgent"
            }
        }
        $UnhealthyCycleCount.Value = 0
        return
    }

    # Both processes exist, but is the endpoint actually producing data?
    if (-not $endpointOk) {
        $UnhealthyCycleCount.Value = $UnhealthyCycleCount.Value + 1
        Write-Log "WATCHDOG: processes alive but endpoint unhealthy (cycle $($UnhealthyCycleCount.Value)/$EndpointUnhealthyCyclesBeforeRestart)" "WARN"
        if ($UnhealthyCycleCount.Value -ge $EndpointUnhealthyCyclesBeforeRestart) {
            Write-Log "WATCHDOG: forcing restart of HWiNFO64 + RemoteHWInfo (data not flowing despite live processes)" "WARN"
            Send-Alert -Title "Watchdog: data stalled" -Body "Forcing HWiNFO + RemoteHWInfo restart" -Priority "urgent"
            Stop-Process -Name RemoteHWInfo -Force -ErrorAction SilentlyContinue
            Stop-Process -Name HWiNFO64 -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Process $script:ResolvedHWiNFO
            Start-Sleep -Seconds 15
            Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
            Start-Sleep -Seconds 5
            $hwCheck = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            if ($hwCheck) { $script:HWiNFOStartTime = $hwCheck.StartTime }
            $UnhealthyCycleCount.Value = 0
        }
    } else {
        $UnhealthyCycleCount.Value = 0
    }

    if ($EnableFipha -and $script:ResolvedFipha) {
        $fpProc = Get-Process fipha -ErrorAction SilentlyContinue
        if (-not $fpProc) {
            Write-Log "WATCHDOG: fipha process gone, restarting..." "WARN"
            if (Test-Path $script:ResolvedFipha) {
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                try {
                    $proc = Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    $fpProc = Get-Process fipha -ErrorAction SilentlyContinue
                    if ($fpProc) {
                        Write-Log "WATCHDOG: fipha restarted (PID $($fpProc.Id))"
                    } else {
                        Write-Log "WATCHDOG: fipha exited immediately again (check its own config/log)" "WARN"
                    }
                } catch {
                    Write-Log "WATCHDOG: fipha restart threw: $_" "WARN"
                }
            }
        }
    }
}

# === MAIN LOOP ================================================================

function Start-ThermalGuard {

    Write-Log "=========================================="
    Write-Log "HWiNFO Thermal Guard v$ScriptVersion started"
    Write-Log "=========================================="
    Write-Log "PowerShell:      $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Log "GPU Profile:     $GPUProfile"
    Write-Log "CPU Monitoring:  $(if ($EnableCPU) {'ON'} else {'OFF'})"
    Write-Log "GPU Monitoring:  $(if ($EnableGPU) {'ON'} else {'OFF'})"
    Write-Log "ntfy:            $(if ($EnableNtfy) {'ON'} else {'OFF'})"
    Write-Log "All-temps report: $(if ($EnableAllTempsReport) {"ON (>$AllTempsThreshold C)"} else {'OFF'})"
    Write-Log "fipha:           $(if ($EnableFipha) {'ON'} else {'OFF'})"
    Write-Log "Sensors:         $($Sensors.Count) configured"
    Write-Log "Polling:         every ${PollInterval}s"
    Write-Log "Stage 2 after ${Stage2Delay}s / Stage 3 after ${Stage3Delay}s"
    Write-Log "Watchdog:        $(if ($EnableWatchdog) {'ON'} else {'OFF'})"
    Write-Log "12h Reset:       $(if ($EnableHWiNFO12hReset) {"ON (after $HWiNFOMaxRuntimeMin min)"} else {'OFF'})"

    try {
        $null = New-ItemProperty -Path "HKCU:\SOFTWARE\HWiNFO64\Settings" -Name "SensorsSM" `
            -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Shared Memory   Registry key set"
    } catch {
        Write-Log "Shared Memory   Registry access failed: $_" "WARN"
    }

    $ready = Test-Requirements
    if (-not $ready) {
        Write-Log "Software check failed, waiting 30s and retrying once..." "ERROR"
        Start-Sleep -Seconds 30
        $ready = Test-Requirements
        if (-not $ready) {
            Write-Log "Software check failed again. Exiting." "ERROR"
            Send-Toast -Title "ThermalGuard error" -Body "Required components missing. See log."
            exit 1
        }
    }

    if (-not $script:HWiNFOStartTime) {
        $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
        $script:HWiNFOStartTime = if ($hwProc) { $hwProc.StartTime } else { Get-Date }
    }

    $triggerTimestamps      = @{}
    $stage2Executed         = @{}
    $warnSent               = @{}
    $missingSensorCounts    = @{}
    $missingSensorLastAlert = @{}
    $endpointDown           = $false
    $lastEndpointAlert      = $null
    $globalStage2Executed   = $false
    $lastWatchdogRun        = $null
    $unhealthyCycleCount    = 0
    $selfTestPrinted        = $false

    while ($true) {
        if ($EnableWatchdog) {
            Invoke-Watchdog -LastWatchdogRun ([ref]$lastWatchdogRun) -UnhealthyCycleCount ([ref]$unhealthyCycleCount)
        }

        $sensorData = Get-HWiNFOSensors

        if ($null -eq $sensorData) {
            if (-not $endpointDown) {
                Write-Log "Endpoint not reachable: $HWiNFO_URL" "ERROR"
                $endpointDown = $true
            }
            if (($null -eq $lastEndpointAlert) -or (((Get-Date) - $lastEndpointAlert).TotalMinutes -ge $EndpointAlertIntervalMinutes)) {
                Send-Alert -Title "ThermalGuard data source offline" -Body "No sensor data." -Priority "urgent"
                $lastEndpointAlert = Get-Date
                $lastWatchdogRun = $null
            }
            Start-Sleep -Seconds $PollInterval
            continue
        }

        if ($endpointDown) {
            Write-Log "Endpoint reachable again"
            $endpointDown      = $false
            $lastEndpointAlert = $null
        }

        Invoke-AllTempsReportCheck -SensorData $sensorData
        Invoke-PerfLimitCheck -SensorData $sensorData

        # Report finding #10: explicit self-test on the first successful
        # poll so an operator can verify exactly which sensor each
        # configured entry actually resolved to.
        if (-not $selfTestPrinted) {
            Write-Log "=== Sensor self-test (first successful poll) ==="
            foreach ($sensor in $Sensors) {
                if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
                if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }
                $candidates = $sensorData.readings | Where-Object {
                    $_.labelOriginal -eq $sensor.SensorMatch -or $_.labelUser -eq $sensor.SensorMatch -or
                    $_.labelOriginal -like "*$($sensor.SensorMatch)*" -or $_.labelUser -like "*$($sensor.SensorMatch)*"
                }
                # Mirror Find-SensorValue's disambiguation order so the self-test
                # log shows exactly the reading that will actually be monitored,
                # not just whichever one happened to come first in the JSON.
                if ($candidates.Count -gt 1 -and $sensor.PreferredSensorIndex) {
                    $byIndex = $candidates | Where-Object { $_.sensorIndex -eq $sensor.PreferredSensorIndex }
                    if ($byIndex) { $candidates = $byIndex }
                }
                if ($candidates.Count -gt 1 -and $sensor.Type -eq "fan") {
                    $byUnit = $candidates | Where-Object { [string]$_.unit -eq "RPM" }
                    if ($byUnit) { $candidates = $byUnit }
                }
                $reading = $candidates | Select-Object -First 1
                if ($reading) {
                    Write-Log "  $($sensor.Name) -> labelOriginal='$($reading.labelOriginal)' sensorIndex=$($reading.sensorIndex) readingId=$($reading.readingId) unit=$($reading.unit) value=$($reading.value)"
                } else {
                    Write-Log "  $($sensor.Name) -> NO MATCH for '$($sensor.SensorMatch)'" "WARN"
                }
            }
            Write-Log "=== End self-test ==="
            $selfTestPrinted = $true
        }

        $gpuLoad = if ($EnableGPU) { Find-GPULoad -SensorData $sensorData } else { $null }

        foreach ($sensor in $Sensors) {
            if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
            if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }

            $sName = $sensor.Name
            $unitHint = if ($sensor.Type -eq "fan") { "RPM" } else { $null }
            $value = Find-SensorValue -SensorData $sensorData -Match $sensor.SensorMatch -PreferredSensorIndex $sensor.PreferredSensorIndex -PreferredUnit $unitHint

            if ($null -eq $value) {
                $missingSensorCounts[$sName] = [int]$missingSensorCounts[$sName] + 1
                if ($missingSensorCounts[$sName] -ge $MissingSensorAlertAfterPolls) {
                    $lastMissingAlert = $missingSensorLastAlert[$sName]
                    if (($null -eq $lastMissingAlert) -or (((Get-Date) - $lastMissingAlert).TotalMinutes -ge $MissingSensorAlertIntervalMinutes)) {
                        Write-Log "Sensor missing: $sName ('$($sensor.SensorMatch)')" "ERROR"
                        Send-Alert -Title "Sensor missing" -Body "$sName not found" -Priority "urgent"
                        $missingSensorLastAlert[$sName] = Get-Date
                    }
                }
                continue
            }

            if ($missingSensorCounts.ContainsKey($sName)) {
                if ($missingSensorCounts[$sName] -ge $MissingSensorAlertAfterPolls) {
                    Write-Log "$sName found again: $value"
                }
                $missingSensorCounts.Remove($sName)
                $missingSensorLastAlert.Remove($sName)
            }

            $isCritical = $false

            if ($sensor.Type -eq "temp") {
                if ($value -ge $sensor.WarnThreshold -and -not $warnSent[$sName]) {
                    Write-Log "${sName}: WARNING ${value} degrees (threshold: $($sensor.WarnThreshold))" "WARN"
                    Send-Alert -Title "$sName warning" -Body "${value} degrees reached" -Priority "high"
                    $warnSent[$sName] = $true
                }
                $isCritical = ($value -ge $sensor.CritThreshold)
            }
            elseif ($sensor.Type -eq "fan") {
                if ($null -ne $gpuLoad -and $gpuLoad -ge $GPULoadThreshold) {
                    if ($value -le $sensor.WarnThreshold -and $value -gt $sensor.CritThreshold -and -not $warnSent[$sName]) {
                        Write-Log "${sName}: WARNING ${value} RPM at ${gpuLoad}% load" "WARN"
                        Send-Alert -Title "$sName warning" -Body "${value} RPM at ${gpuLoad}% load" -Priority "high"
                        $warnSent[$sName] = $true
                    }
                    $isCritical = ($value -le $sensor.CritThreshold)
                }
            }

            if ($isCritical) {
                if (-not $triggerTimestamps[$sName]) {
                    $triggerTimestamps[$sName] = Get-Date
                    Write-Log "${sName}: CRITICAL value=$value, timer started" "CRIT"
                    Send-Alert -Title "$sName CRITICAL" -Body "Value: $value, shutdown in ${Stage3Delay}s if sustained" -Priority "urgent"
                    $warnSent[$sName] = $true
                }

                $elapsed = [int](((Get-Date) - $triggerTimestamps[$sName]).TotalSeconds)

                if ($elapsed -ge $Stage2Delay -and -not $stage2Executed[$sName]) {
                    Write-Log "${sName}: ${elapsed}s critical, stage 2" "CRIT"
                    Send-Alert -Title "Stage 2: processes killed" -Body "$sName at $value for ${elapsed}s" -Priority "urgent"
                    if (-not $globalStage2Executed) {
                        Invoke-KillProcesses
                        $globalStage2Executed = $true
                    }
                    $stage2Executed[$sName] = $true
                }

                if ($elapsed -ge $Stage3Delay) {
                    Write-Log "${sName}: ${elapsed}s critical, stage 3: SHUTDOWN" "CRIT"
                    Invoke-Shutdown
                    return
                }
            }
            else {
                if ($triggerTimestamps[$sName]) {
                    Write-Log "${sName}: value normalized ($value), timer reset"
                    $triggerTimestamps.Remove($sName)
                    $stage2Executed.Remove($sName)
                    if ($triggerTimestamps.Count -eq 0) { $globalStage2Executed = $false }
                }
                if ($sensor.Type -eq "temp" -and $value -lt ($sensor.WarnThreshold * 0.95)) {
                    $warnSent.Remove($sName)
                }
                elseif ($sensor.Type -eq "fan") {
                    if (($null -eq $gpuLoad) -or ($gpuLoad -lt $GPULoadThreshold) -or ($value -ge ($sensor.WarnThreshold + 50))) {
                        $warnSent.Remove($sName)
                    }
                }
            }
        }

        Start-Sleep -Seconds $PollInterval
    }
}

# === START ====================================================================
try {
    Start-ThermalGuard
} catch {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $crashMsg = "[$ts] [FATAL] Script crashed: $_"
    Write-Host $crashMsg
    $crashLog = Join-Path $env:USERPROFILE "HWiNFO-ThermalGuard"
    if (-not (Test-Path $crashLog)) { New-Item -ItemType Directory -Path $crashLog -Force | Out-Null }
    Add-Content -Path (Join-Path $crashLog "thermalguard.log") -Value $crashMsg -Encoding UTF8
    throw
}
