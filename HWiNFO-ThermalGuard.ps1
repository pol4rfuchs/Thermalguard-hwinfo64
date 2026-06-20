# ============================================================================
# HWiNFO Thermal Guard v1.4
# 3-Stage Protection: Alert -> Kill -> Shutdown
# Auto-Scan, Auto-Download, Watchdog, HWiNFO 12h-Reset, PS5+PS7
# ============================================================================

# === USER CONFIGURATION ======================================================

# --- PATHS (OPTIONAL) --------------------------------------------------------
# Leave empty = automatic scan + download if needed
# Set path = override, used directly without scanning
$HWiNFO_Path       = ""    # e.g. "C:\Program Files\HWiNFO64\HWiNFO64.exe"
$RemoteHWInfo_Path  = ""    # e.g. "C:\Tools\RemoteHWInfo\RemoteHWInfo.exe"
$fipha_Path = ""    # e.g. "C:\Tools\fip-ha-0.0.2.0\fipha.exe"

# --- GPU PROFILE -------------------------------------------------------------
# "AUTO"    -> Auto-detects whether NVIDIA or AMD is installed
# "NVIDIA"  -> Manual override: RTX 5070 Ti, RTX 4090, etc.
# "AMD"     -> Manual override: RX 9070 XT, RX 6800 XT, etc.
$GPUProfile = "AUTO"

# --- TOGGLES -----------------------------------------------------------------
$EnableCPU  = $true
$EnableGPU  = $true
$EnableFipha = $true    # fipha: HWiNFO -> MQTT -> Home Assistant
$EnableNtfy = $false    # $false = Windows Toast only, no ntfy

# --- WATCHDOG ----------------------------------------------------------------
$EnableWatchdog      = $true    # Process watchdog for HWiNFO + RemoteHWInfo
$WatchdogIntervalSec = 60      # Watchdog checks every X seconds
$EnableHWiNFO12hReset = $true  # HWiNFO Free 12h limit: automatic restart
$HWiNFOMaxRuntimeMin  = 690   # Restart after X minutes (690 = 11.5h, buffer before 12h)

# --- ntfy CONFIGURATION (only relevant if $EnableNtfy = $true) ---------------
$NTFY_URL   = "https://ntfy.example.com"
$NTFY_TOPIC = "thermalguard"

# --- THRESHOLDS --------------------------------------------------------------
$CPU_WarnTemp    = 85
$CPU_CritTemp    = 91
$GPU_WarnTemp    = 83
$GPU_CritTemp    = 90
$GPU_HotspotWarn = 95    # AMD only
$GPU_HotspotCrit = 100   # AMD only
$GPU_FanWarnRPM  = 300
$GPU_FanCritRPM  = 0
$GPULoadThreshold = 50

# --- TIMING ------------------------------------------------------------------
$PollInterval = 5
$Stage2Delay  = 30
$Stage3Delay  = 90

# --- PROCESSES KILLED AT STAGE 2 ---------------------------------------------
$KillProcesses = @(
    "TslGame"
    "Stalker2-Win64-Shipping"
    "obs64"
    "chrome"
    "firefox"
    "floorp"
)

# --- ENDPOINT ----------------------------------------------------------------
$HWiNFO_URL = "http://localhost:60000/json.json"

# --- INSTALL TARGET FOLDER ---------------------------------------------------
$ToolsDir = "C:\Tools"

# === INTERNAL CONFIGURATION ==================================================

$MissingSensorAlertAfterPolls      = 3
$MissingSensorAlertIntervalMinutes = 30
$EndpointAlertIntervalMinutes      = 15
$LogDir       = "$env:USERPROFILE\HWiNFO-ThermalGuard"
$LogFile      = Join-Path $LogDir "thermalguard.log"
$MaxLogSizeMB = 10

# === POWERSHELL COMPATIBILITY ================================================

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error "PowerShell 5.1 or higher required. Current: $($PSVersionTable.PSVersion)"
    exit 1
}

# === LOGGING =================================================================

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


# === HARDWARE DETECTION ======================================================

function Detect-GPUProfile {
    Write-Log "GPU Detection   Starting..."

    # Method 1: Windows WMI (always works, even without HWiNFO)
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft|Remote|Virtual' }
        foreach ($gpu in $gpus) {
            $name = $gpu.Name.ToUpper()
            Write-Log "GPU Detection   Found: $($gpu.Name)"
            if ($name -match 'NVIDIA|GEFORCE|RTX|GTX|QUADRO') {
                Write-Log "GPU Detection   [OK] NVIDIA detected"
                return "NVIDIA"
            }
            if ($name -match 'AMD|RADEON|RX ') {
                Write-Log "GPU Detection   [OK] AMD detected"
                return "AMD"
            }
        }
    } catch {
        Write-Log "GPU Detection   WMI failed: $_" "WARN"
    }

    # Method 2: HWiNFO JSON (if endpoint is already running)
    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($r.hwinfo -and $r.hwinfo.sensors) {
            foreach ($sensor in $r.hwinfo.sensors) {
                $sName = $sensor.sensorNameOriginal.ToUpper()
                if ($sName -match 'NVIDIA|GEFORCE|RTX|GTX') {
                    Write-Log "GPU Detection   [OK] NVIDIA detected (via HWiNFO)"
                    return "NVIDIA"
                }
                if ($sName -match 'AMD|RADEON|RX ') {
                    Write-Log "GPU Detection   [OK] AMD detected (via HWiNFO)"
                    return "AMD"
                }
            }
        }
    } catch {
        # Endpoint not yet available — normal on first start
    }

    Write-Log "GPU Detection   [ERROR] No supported GPU detected" "ERROR"
    Write-Log "  -> Set \$GPUProfile manually to 'NVIDIA' or 'AMD'" "ERROR"
    return $null
}

# === GPU PROFILES ============================================================

$GPUProfiles = @{
    "NVIDIA" = @{
        TempMatch    = "GPU Temperature"
        TempWarn     = $GPU_WarnTemp
        TempCrit     = $GPU_CritTemp
        HotspotMatch = $null
        FanMatch     = "GPU Fan1"
        FanWarn      = $GPU_FanWarnRPM
        FanCrit      = $GPU_FanCritRPM
        LoadMatch    = "GPU Core Load"
    }
    "AMD" = @{
        TempMatch    = "GPU Temperature"
        TempWarn     = $GPU_WarnTemp
        TempCrit     = $GPU_CritTemp
        HotspotMatch = "GPU Hot Spot Temperature"
        HotspotWarn  = $GPU_HotspotWarn
        HotspotCrit  = $GPU_HotspotCrit
        FanMatch     = "GPU Fan"
        FanWarn      = $GPU_FanWarnRPM
        FanCrit      = $GPU_FanCritRPM
        LoadMatch    = "GPU Utilization"
    }
}

# === RESOLVE GPU PROFILE =====================================================

if ($GPUProfile -eq "AUTO") {
    $detected = Detect-GPUProfile
    if ($detected) {
        $GPUProfile = $detected
    } else {
        Write-Host "ERROR: GPU could not be detected. Set \$GPUProfile manually."
        exit 1
    }
}

if (-not $GPUProfiles.ContainsKey($GPUProfile)) {
    Write-Host "ERROR: Unknown GPU profile '$GPUProfile'. Allowed: AUTO, NVIDIA, AMD"
    exit 1
}

# === BUILD SENSOR LIST =======================================================

$Sensors = @(
    @{
        Name          = "CPU Tctl/Tdie"
        SensorMatch   = "CPU (Tctl/Tdie)"
        WarnThreshold = $CPU_WarnTemp
        CritThreshold = $CPU_CritTemp
        Type          = "temp"
        Group         = "CPU"
    }
)

if ($EnableGPU) {
    $p = $GPUProfiles[$GPUProfile]
    $Sensors += @{
        Name = "GPU Temperature"; SensorMatch = $p.TempMatch
        WarnThreshold = $p.TempWarn; CritThreshold = $p.TempCrit
        Type = "temp"; Group = "GPU"
    }
    if ($p.HotspotMatch) {
        $Sensors += @{
            Name = "GPU Hotspot"; SensorMatch = $p.HotspotMatch
            WarnThreshold = $p.HotspotWarn; CritThreshold = $p.HotspotCrit
            Type = "temp"; Group = "GPU"
        }
    }
    $Sensors += @{
        Name = "GPU Fan"; SensorMatch = $p.FanMatch
        WarnThreshold = $p.FanWarn; CritThreshold = $p.FanCrit
        Type = "fan"; Group = "GPU"
    }
}

# === DEPENDENCY SCAN + AUTO-DOWNLOAD =========================================

function Find-Executable {
    param([string]$Name, [string[]]$SearchPaths)
    foreach ($dir in $SearchPaths) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $found = Get-ChildItem -Path $dir -Filter $Name -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    # PATH search
    $inPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

function Resolve-HWiNFO {
    # Manual override?
    if ($script:HWiNFO_Path -and (Test-Path $script:HWiNFO_Path)) {
        Write-Log "HWiNFO64        [OK] Override: $($script:HWiNFO_Path)"
        return $script:HWiNFO_Path
    }

    Write-Log "HWiNFO64        Scanning..."
    $scanPaths = @(
        "$env:ProgramFiles\HWiNFO64"
        "${env:ProgramFiles(x86)}\HWiNFO64"
        "$ToolsDir\HWiNFO64"
        "$ToolsDir"
        "$env:USERPROFILE\Desktop"
        "$env:USERPROFILE\Downloads"
    )
    $found = Find-Executable -Name "HWiNFO64.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "HWiNFO64        [OK] Found: $found"
        return $found
    }

    # Auto-install via winget
    Write-Log "HWiNFO64        [MISSING] Attempting installation via winget..." "WARN"
    try {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            $result = & winget install REALiX.HWiNFO --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1
            Write-Log "winget: $($result -join ' ')"
            # Scan again after install
            $found = Find-Executable -Name "HWiNFO64.exe" -SearchPaths $scanPaths
            if ($found) {
                Write-Log "HWiNFO64        [OK] Installed: $found"
                return $found
            }
        }
    } catch {
        Write-Log "winget failed: $_" "WARN"
    }

    Write-Log "HWiNFO64        [ERROR] Could not be installed" "ERROR"
    Write-Log "  -> Manual: https://www.hwinfo.com/download/" "ERROR"
    Write-Log "  -> Or set path: `$HWiNFO_Path = 'C:\...\HWiNFO64.exe'" "ERROR"
    return $null
}

function Resolve-RemoteHWInfo {
    # Manual override?
    if ($script:RemoteHWInfo_Path -and (Test-Path $script:RemoteHWInfo_Path)) {
        Write-Log "RemoteHWInfo    [OK] Override: $($script:RemoteHWInfo_Path)"
        return $script:RemoteHWInfo_Path
    }

    Write-Log "RemoteHWInfo    Scanning..."
    $scanPaths = @(
        "$ToolsDir\RemoteHWInfo"
        "$ToolsDir"
        "$env:USERPROFILE\Desktop"
        "$env:USERPROFILE\Downloads"
        (Split-Path $PSCommandPath -Parent -ErrorAction SilentlyContinue)
    )
    $found = Find-Executable -Name "RemoteHWInfo.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "RemoteHWInfo    [OK] Found: $found"
        return $found
    }

    # Auto-download from GitHub
    Write-Log "RemoteHWInfo    [MISSING] Downloading..." "WARN"
    try {
        $downloadUrl = "https://github.com/Demion/remotehwinfo/releases/download/v0.5/RemoteHWInfo_v0.5.zip"
        $targetDir   = Join-Path $ToolsDir "RemoteHWInfo"
        $zipFile     = Join-Path $env:TEMP "RemoteHWInfo_v0.5.zip"

        if (-not (Test-Path $ToolsDir)) {
            New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
        }
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        Write-Log "  Downloading: $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing -TimeoutSec 60
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

    Write-Log "RemoteHWInfo    [ERROR] Could not be installed" "ERROR"
    Write-Log "  -> Manual: https://github.com/Demion/remotehwinfo/releases/tag/v0.5" "ERROR"
    return $null
}

function Resolve-Fipha {
    if (-not $EnableFipha) {
        Write-Log "fipha           [OFF]"
        return $null
    }

    if ($script:fipha_Path -and (Test-Path $script:fipha_Path)) {
        Write-Log "fipha           [OK] Override: $($script:fipha_Path)"
        return $script:fipha_Path
    }

    Write-Log "fipha           Scanning..."
    $scanPaths = @(
        "$ToolsDir\fip-ha-0.0.2.0"
        "$ToolsDir\fipha"
        "$ToolsDir"
        "$env:USERPROFILE\Desktop"
        "$env:USERPROFILE\Downloads"
        (Split-Path $PSCommandPath -Parent -ErrorAction SilentlyContinue)
    )
    $found = Find-Executable -Name "fipha.exe" -SearchPaths $scanPaths
    if ($found) {
        Write-Log "fipha           [OK] Found: $found"
        return $found
    }

    Write-Log "fipha           [MISSING] Not found" "WARN"
    Write-Log "  -> Download: https://github.com/mhwlng/fipha/releases" "WARN"
    Write-Log "  -> Or set path: \$fipha_Path = 'C:\...\fipha.exe'" "WARN"
    return $null
}

function Resolve-BurntToast {
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Write-Log "BurntToast      [MISSING] Installing..." "WARN"
        try {
            Install-Module BurntToast -Force -Scope CurrentUser -ErrorAction Stop
            Write-Log "BurntToast      [OK] Installed"
        } catch {
            Write-Log "BurntToast      [ERROR] $_" "ERROR"
            Write-Log "  -> Manual: Install-Module BurntToast -Force -Scope CurrentUser" "ERROR"
            return $false
        }
    } else {
        Write-Log "BurntToast      [OK]"
    }
    Import-Module BurntToast -ErrorAction SilentlyContinue
    return $true
}

# === SOFTWARE CHECK ===========================================================

function Test-Requirements {
    Write-Log "=== Software Check ==="
    Write-Log "PowerShell      [OK] v$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $ok = $true

    # BurntToast
    if (-not (Resolve-BurntToast)) { $ok = $false }

    # HWiNFO64
    $script:ResolvedHWiNFO = Resolve-HWiNFO
    if (-not $script:ResolvedHWiNFO) { $ok = $false }

    # RemoteHWInfo
    $script:ResolvedRemoteHWInfo = Resolve-RemoteHWInfo
    if (-not $script:ResolvedRemoteHWInfo) { $ok = $false }

    # Check if HWiNFO64 is running
    $hw = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
    if ($hw) {
        Write-Log "HWiNFO64 Proc   [OK] PID $($hw.Id)"
    } else {
        if ($script:ResolvedHWiNFO) {
            Write-Log "HWiNFO64 Proc   [STARTING]..." "WARN"
            Start-Process $script:ResolvedHWiNFO
            Write-Log "  Waiting 15s for sensor initialization..."
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

    # Check if RemoteHWInfo is running
    $rh = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
    if ($rh) {
        Write-Log "RemoteHWInfo Proc [OK] PID $($rh.Id)"
    } else {
        if ($script:ResolvedRemoteHWInfo) {
            Write-Log "RemoteHWInfo Proc [STARTING]..." "WARN"
            Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
            Write-Log "  Waiting 5s for HTTP server..."
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

    # HTTP endpoint reachable?
    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5
        if ($r.hwinfo -and $r.hwinfo.readings) {
            Write-Log "HTTP Endpoint   [OK] $HWiNFO_URL ($($r.hwinfo.readingCount) Readings)"
        } else {
            Write-Log "HTTP Endpoint   [ERROR] Invalid JSON" "ERROR"
            $ok = $false
        }
    } catch {
        Write-Log "HTTP Endpoint   [ERROR] Not reachable: $HWiNFO_URL" "ERROR"
        $ok = $false
    }

    # ntfy
    if ($EnableNtfy) {
        try {
            Invoke-RestMethod -Uri "$NTFY_URL/$NTFY_TOPIC" -Method Post -Body "ThermalGuard Start-Test" `
                -Headers @{ "Title" = "ThermalGuard started"; "Tags" = "white_check_mark" } `
                -TimeoutSec 5 | Out-Null
            Write-Log "ntfy            [OK] $NTFY_URL/$NTFY_TOPIC"
        } catch {
            Write-Log "ntfy            [WARNING] Not reachable" "WARN"
        }
    } else {
        Write-Log "ntfy            [OFF]"
    }

    # fipha (optional)
    if ($EnableFipha) {
        $script:ResolvedFipha = Resolve-Fipha
        if ($script:ResolvedFipha) {
            $fp = Get-Process fipha -ErrorAction SilentlyContinue
            if ($fp) {
                Write-Log "fipha Proc      [OK] PID $($fp.Id)"
            } else {
                Write-Log "fipha Proc      [STARTING]..." "WARN"
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir
                Start-Sleep -Seconds 5
                $fp = Get-Process fipha -ErrorAction SilentlyContinue
                if ($fp) {
                    Write-Log "fipha Proc      [OK] PID $($fp.Id)"
                } else {
                    Write-Log "fipha Proc      [WARNING] Could not be started" "WARN"
                    # Not a hard fail — fipha is optional
                }
            }
        }
    }

    Write-Log "=== Software Check complete ==="
    return $ok
}

# === EXPORT PATHS (for .bat) =================================================
# When called with -Resolve: output paths only and exit

if ($args -contains "-Resolve") {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $hw = Resolve-HWiNFO
    $rh = Resolve-RemoteHWInfo
    $fp = if ($EnableFipha) { Resolve-Fipha } else { "" }
    
    $pathFile = Join-Path $env:TEMP "thermalguard_paths.txt"
    @(
        "HWINFO_EXE=$hw"
        "REMOTEHWINFO_EXE=$rh"
        "FIPHA_EXE=$fp"
    ) | Set-Content -Path $pathFile -Encoding UTF8
    Write-Host "Paths written: $pathFile"
    exit 0
}

# === NOTIFICATIONS ============================================================

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        New-BurntToastNotification -Text $Title, $Body -Sound "Alarm" -UniqueIdentifier "ThermalGuard"
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

function Send-Alert {
    param([string]$Title, [string]$Body, [string]$Priority = "high")
    Send-Toast -Title $Title -Body $Body
    Send-Ntfy  -Title $Title -Body $Body -Priority $Priority
}

# === SENSOR QUERY =============================================================

function Get-HWiNFOSensors {
    try {
        $response = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5
        return $response.hwinfo
    } catch {
        return $null
    }
}

function Find-SensorValue {
    param($SensorData, [string]$Match)
    $exactMatches   = @()
    $partialMatches = @()
    foreach ($reading in $SensorData.readings) {
        $lo = [string]$reading.labelOriginal
        $lu = [string]$reading.labelUser
        if ($lo -eq $Match -or $lu -eq $Match)             { $exactMatches   += $reading; continue }
        if ($lo -like "*$Match*" -or $lu -like "*$Match*")  { $partialMatches += $reading }
    }
    $m = if ($exactMatches.Count -gt 0) { $exactMatches } else { $partialMatches }
    if ($m.Count -gt 1 -and -not $script:LoggedSensorMatchWarnings[$Match]) {
        $labels = ($m | Select-Object -First 5 | ForEach-Object { $_.labelOriginal }) -join ' | '
        Write-Log "Ambiguous SensorMatch '$Match': $labels" "WARN"
        $script:LoggedSensorMatchWarnings[$Match] = $true
    }
    if ($m.Count -eq 0) { return $null }
    try { return [double]$m[0].value } catch { return $null }
}

function Find-GPULoad {
    param($SensorData)
    $loadMatch = $GPUProfiles[$GPUProfile].LoadMatch
    return Find-SensorValue -SensorData $SensorData -Match $loadMatch
}

# === STAGE 2 & 3 ==============================================================

function Invoke-KillProcesses {
    Write-Log "=== STAGE 2: Killing processes ===" "CRIT"
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
    Send-Alert -Title "EMERGENCY SHUTDOWN" -Body "System is shutting down!" -Priority "urgent"
    Start-Sleep -Seconds 2
    & shutdown.exe /s /f /t 0
}

# === WATCHDOG ================================================================

function Invoke-Watchdog {
    param(
        [ref]$HWiNFOStartTime,
        [ref]$LastWatchdogRun
    )

    $now = Get-Date

    # Only run every $WatchdogIntervalSec seconds
    if ($LastWatchdogRun.Value -and (($now - $LastWatchdogRun.Value).TotalSeconds -lt $WatchdogIntervalSec)) {
        return
    }
    $LastWatchdogRun.Value = $now

    # --- HWiNFO64 process check ---
    $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
    if (-not $hwProc) {
        Write-Log "WATCHDOG: HWiNFO64 no longer active — restarting..." "WARN"
        if ($script:ResolvedHWiNFO -and (Test-Path $script:ResolvedHWiNFO)) {
            Start-Process $script:ResolvedHWiNFO
            Start-Sleep -Seconds 15
            $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            if ($hwProc) {
                Write-Log "WATCHDOG: HWiNFO64 restarted (PID $($hwProc.Id))" "INFO"
                $HWiNFOStartTime.Value = $now
            } else {
                Write-Log "WATCHDOG: HWiNFO64 restart failed" "ERROR"
                Send-Alert -Title "Watchdog: HWiNFO64 down" -Body "Restart failed" -Priority "urgent"
            }
        } else {
            Write-Log "WATCHDOG: HWiNFO64 path not available" "ERROR"
            Send-Alert -Title "Watchdog: HWiNFO64 down" -Body "Path not found" -Priority "urgent"
        }
    }

    # --- HWiNFO Free 12h reset ---
    if ($EnableHWiNFO12hReset -and $hwProc -and $HWiNFOStartTime.Value) {
        $runtimeMin = ($now - $HWiNFOStartTime.Value).TotalMinutes
        if ($runtimeMin -ge $HWiNFOMaxRuntimeMin) {
            Write-Log "WATCHDOG: HWiNFO64 running for $([int]$runtimeMin) minutes — 12h reset..." "WARN"
            Send-Alert -Title "HWiNFO 12h Reset" -Body "Automatic restart (Free limit)" -Priority "default"

            # Stop HWiNFO
            Stop-Process -Name HWiNFO64 -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3

            # Stop RemoteHWInfo too (needs new Shared Memory)
            Stop-Process -Name RemoteHWInfo -Force -ErrorAction SilentlyContinue
            # Stop fipha too (needs new Shared Memory)
            if ($EnableFipha) {
                Stop-Process -Name fipha -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 2

            # Restart HWiNFO
            Start-Process $script:ResolvedHWiNFO
            Write-Log "WATCHDOG: Waiting 15s for HWiNFO sensor init..."
            Start-Sleep -Seconds 15

            # Restart RemoteHWInfo
            if ($script:ResolvedRemoteHWInfo -and (Test-Path $script:ResolvedRemoteHWInfo)) {
                Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
                Write-Log "WATCHDOG: Waiting 5s for RemoteHWInfo..."
                Start-Sleep -Seconds 5
            }

            # Restart fipha
            if ($EnableFipha -and $script:ResolvedFipha -and (Test-Path $script:ResolvedFipha)) {
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir
                Write-Log "WATCHDOG: Waiting 5s for fipha..."
                Start-Sleep -Seconds 5
            }

            $HWiNFOStartTime.Value = Get-Date
            $hwCheck = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
            $rhCheck = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
            if ($hwCheck -and $rhCheck) {
                Write-Log "WATCHDOG: 12h reset successful — HWiNFO (PID $($hwCheck.Id)) + RemoteHWInfo (PID $($rhCheck.Id))" "INFO"
            } else {
                Write-Log "WATCHDOG: 12h reset — not all processes started" "ERROR"
                Send-Alert -Title "Watchdog: 12h Reset Problem" -Body "HWiNFO or RemoteHWInfo missing after reset" -Priority "urgent"
            }
            return
        }
    }

    # --- RemoteHWInfo process check ---
    $rhProc = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
    if (-not $rhProc) {
        Write-Log "WATCHDOG: RemoteHWInfo no longer active — restarting..." "WARN"
        if ($script:ResolvedRemoteHWInfo -and (Test-Path $script:ResolvedRemoteHWInfo)) {
            Start-Process $script:ResolvedRemoteHWInfo -ArgumentList "-hwinfo=1 -gpuz=0 -afterburner=0" -WindowStyle Hidden
            Start-Sleep -Seconds 5
            $rhProc = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
            if ($rhProc) {
                Write-Log "WATCHDOG: RemoteHWInfo restarted (PID $($rhProc.Id))" "INFO"
            } else {
                Write-Log "WATCHDOG: RemoteHWInfo restart failed" "ERROR"
                Send-Alert -Title "Watchdog: RemoteHWInfo down" -Body "Restart failed" -Priority "urgent"
            }
        } else {
            Write-Log "WATCHDOG: RemoteHWInfo path not available" "ERROR"
        }
    }

    # --- fipha process check (optional) ---
    if ($EnableFipha -and $script:ResolvedFipha) {
        $fpProc = Get-Process fipha -ErrorAction SilentlyContinue
        if (-not $fpProc) {
            Write-Log "WATCHDOG: fipha no longer active — restarting..." "WARN"
            if (Test-Path $script:ResolvedFipha) {
                $fiphaDir = Split-Path $script:ResolvedFipha -Parent
                Start-Process $script:ResolvedFipha -WorkingDirectory $fiphaDir
                Start-Sleep -Seconds 5
                $fpProc = Get-Process fipha -ErrorAction SilentlyContinue
                if ($fpProc) {
                    Write-Log "WATCHDOG: fipha restarted (PID $($fpProc.Id))" "INFO"
                } else {
                    Write-Log "WATCHDOG: fipha restart failed" "WARN"
                }
            }
        }
    }
}

# === MAIN LOOP ===============================================================

function Start-ThermalGuard {

    Write-Log "=========================================="
    Write-Log "HWiNFO Thermal Guard v1.4 started"
    Write-Log "=========================================="
    Write-Log "PowerShell:      $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Log "GPU Profile:     $GPUProfile"
    Write-Log "CPU Monitoring:  $(if ($EnableCPU) {'ON'} else {'OFF'})"
    Write-Log "GPU Monitoring:  $(if ($EnableGPU) {'ON'} else {'OFF'})"
    Write-Log "ntfy:            $(if ($EnableNtfy) {'ON'} else {'OFF'})"
    Write-Log "Sensors:         $($Sensors.Count) configured"
    Write-Log "Polling:         every ${PollInterval}s"
    Write-Log "Stage 2 after ${Stage2Delay}s / Stage 3 after ${Stage3Delay}s"
    Write-Log "Watchdog:        $(if ($EnableWatchdog) {'ON'} else {'OFF'})"
    Write-Log "12h Reset:       $(if ($EnableHWiNFO12hReset) {"ON (after ${HWiNFOMaxRuntimeMin} min)"} else {'OFF'})"

    # Ensure Shared Memory is set in registry
    try {
        $null = New-ItemProperty -Path "HKCU:\SOFTWARE\HWiNFO64\Settings" -Name "SensorsSM" `
            -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Shared Memory   Registry key set"
    } catch {
        Write-Log "Shared Memory   Registry access failed: $_" "WARN"
    }

    # Software check (incl. scan + download + autostart)
    $ready = Test-Requirements
    if (-not $ready) {
        Write-Log "Software check failed — waiting 30s and retrying..." "ERROR"
        Start-Sleep -Seconds 30
        $ready = Test-Requirements
        if (-not $ready) {
            Write-Log "Software check failed again — script exiting." "ERROR"
            Send-Toast -Title "ThermalGuard Error" -Body "Required components missing. See log."
            exit 1
        }
    }

    $triggerTimestamps      = @{}
    $stage2Executed         = @{}
    $warnSent               = @{}
    $missingSensorCounts    = @{}
    $missingSensorLastAlert = @{}
    $endpointDown           = $false
    $lastEndpointAlert      = $null
    $globalStage2Executed   = $false
    $hwInfoStartTime        = Get-Date
    $lastWatchdogRun        = $null

    while ($true) {
        # Watchdog: check processes + 12h reset
        if ($EnableWatchdog) {
            Invoke-Watchdog -HWiNFOStartTime ([ref]$hwInfoStartTime) -LastWatchdogRun ([ref]$lastWatchdogRun)
        }

        $sensorData = Get-HWiNFOSensors

        if ($null -eq $sensorData) {
            if (-not $endpointDown) {
                Write-Log "Endpoint not reachable: $HWiNFO_URL" "ERROR"
                $endpointDown = $true
            }
            if (($null -eq $lastEndpointAlert) -or (((Get-Date) - $lastEndpointAlert).TotalMinutes -ge $EndpointAlertIntervalMinutes)) {
                Send-Alert -Title "ThermalGuard: Data source offline" -Body "No sensor data available." -Priority "urgent"
                $lastEndpointAlert = Get-Date
                # Force immediate watchdog check on endpoint failure
                if ($EnableWatchdog) {
                    $lastWatchdogRun = $null
                }
            }
            Start-Sleep -Seconds $PollInterval
            continue
        }

        if ($endpointDown) {
            Write-Log "Endpoint reachable again" "INFO"
            $endpointDown      = $false
            $lastEndpointAlert = $null
        }

        $gpuLoad = if ($EnableGPU) { Find-GPULoad -SensorData $sensorData } else { $null }

        foreach ($sensor in $Sensors) {
            if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
            if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }

            $sName = $sensor.Name
            $value = Find-SensorValue -SensorData $sensorData -Match $sensor.SensorMatch

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
                    Write-Log "$sName found again: $value" "INFO"
                }
                $missingSensorCounts.Remove($sName)
                $missingSensorLastAlert.Remove($sName)
            }

            $isCritical = $false

            if ($sensor.Type -eq "temp") {
                if ($value -ge $sensor.WarnThreshold -and -not $warnSent[$sName]) {
                    Write-Log "$sName WARNING: ${value} degrees (threshold: $($sensor.WarnThreshold))" "WARN"
                    Send-Alert -Title "$sName Warning" -Body "${value} degrees reached" -Priority "high"
                    $warnSent[$sName] = $true
                }
                $isCritical = ($value -ge $sensor.CritThreshold)
            }
            elseif ($sensor.Type -eq "fan") {
                if ($null -ne $gpuLoad -and $gpuLoad -ge $GPULoadThreshold) {
                    if ($value -le $sensor.WarnThreshold -and $value -gt $sensor.CritThreshold -and -not $warnSent[$sName]) {
                        Write-Log "$sName WARNING: ${value} RPM at ${gpuLoad}% load" "WARN"
                        Send-Alert -Title "$sName Warning" -Body "${value} RPM at ${gpuLoad}% load" -Priority "high"
                        $warnSent[$sName] = $true
                    }
                    $isCritical = ($value -le $sensor.CritThreshold)
                }
            }

            if ($isCritical) {
                if (-not $triggerTimestamps[$sName]) {
                    $triggerTimestamps[$sName] = Get-Date
                    Write-Log "$sName CRITICAL: value=$value — timer started" "CRIT"
                    Send-Alert -Title "$sName CRITICAL" -Body "Value: $value — Shutdown in ${Stage3Delay}s" -Priority "urgent"
                    $warnSent[$sName] = $true
                }

                $elapsed = [int](((Get-Date) - $triggerTimestamps[$sName]).TotalSeconds)

                if ($elapsed -ge $Stage2Delay -and -not $stage2Executed[$sName]) {
                    Write-Log "${sName}: ${elapsed}s critical — Stage 2" "CRIT"
                    Send-Alert -Title "Stage 2: Processes killed" -Body "$sName at $value for ${elapsed}s" -Priority "urgent"
                    if (-not $globalStage2Executed) {
                        Invoke-KillProcesses
                        $globalStage2Executed = $true
                    }
                    $stage2Executed[$sName] = $true
                }

                if ($elapsed -ge $Stage3Delay) {
                    Write-Log "${sName}: ${elapsed}s critical — Stage 3: SHUTDOWN" "CRIT"
                    Invoke-Shutdown
                    return
                }
            }
            else {
                if ($triggerTimestamps[$sName]) {
                    Write-Log "${sName}: value normalized ($value) — timer reset" "INFO"
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

# === START ===================================================================
Start-ThermalGuard
