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

param(
    # Runs ONLY the staged-update installer (stop -> swap -> restart -> health
    # check -> rollback-if-unhealthy), then exits. Used by
    # Approve-ThermalGuardUpdate.ps1 for manual approval, and internally by
    # this same script when $EnableAutoInstall = $true. Never runs the
    # thermal monitoring loop itself when this switch is present.
    [switch]$InstallPendingUpdate,

    # Simulation mode: runs the normal monitoring loop, but Stage 2 (kill)
    # and Stage 3 (shutdown) only LOG what they would do. Alerts (toast/ntfy)
    # are still sent, with a DRYRUN prefix, so the notification path can be
    # tested too. The watchdog, update check and update installer are off.
    [switch]$DryRun,

    # Pretends the CPU temperature is this many degrees C (overrides the real
    # reading of "CPU Tctl/Tdie"). Always implies -DryRun, so it can never
    # cause a real kill/shutdown. Example: -SimulateTemp 95
    [double]$SimulateTemp = [double]::NaN
)

if (-not [double]::IsNaN($SimulateTemp)) { $DryRun = [switch]$true }

# --- VERSION ---------------------------------------------------------------
# Single source of truth for the version number, used in the startup log
# line below. There was a stale "v2.0" hardcoded in two separate places
# after an abandoned v2.0 attempt was reverted - this variable exists so
# that never happens silently again. Bump this and nowhere else.
#
# v1.50: added actual update installation (download, syntax-validate,
# backup, stage, optional auto-swap with health-check rollback) on top of
# the existing v1.49 detect-only update check. See $EnableAutoDownload /
# $EnableAutoInstall in the config block below, and
# Approve-ThermalGuardUpdate.ps1 for the manual-approval path.
#
# v1.51: update installer fixes (installer no longer blocked by the launcher's
# duplicate check, real health marker instead of "Software Check complete",
# rollback always restores the file that was live before the swap, SHA-256
# verification of downloads), data-loss fail-safe, GPU Fan2, temperature unit
# filter, -DryRun / -SimulateTemp, ntfy auth, log retention, Tls11 removed,
# fipha off by default. See README.
$ScriptVersion = "1.52"

# --- TLS (GLOBAL, EARLY) -----------------------------------------------------
# PowerShell 5.1 / .NET Framework does not always default to TLS 1.2, which
# some servers reject outright. This used to only be set locally inside
# Resolve-BurntToast right before its PSGallery call - meaning any earlier
# network call (e.g. the ntfy startup check, if Resolve-BurntToast is ever
# skipped because the module is already installed) ran without it. Setting
# it here, before anything else runs, means every HTTPS call in this process
# gets it, not just BurntToast's.
try {
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12
} catch {
    # Older .NET Framework builds may not expose the Tls12 constant at all;
    # in that case just leave the OS default in place rather than crash.
}

# === USER CONFIGURATION ======================================================

# --- PATHS (OPTIONAL OVERRIDE) ------------------------------------------------
# Leave empty to auto-scan a fixed allowlist of folders (see Find-Executable).
# Set explicitly if your installation lives outside that allowlist, e.g. on
# the Desktop or in a Downloads folder - those are intentionally NOT scanned
# automatically any more (security hardening, see report finding #19).
$HWiNFO_Path       = ""
$RemoteHWInfo_Path = ""
$Fipha_Path        = ""

# --- GPU PROFILE --------------------------------------------------------------
# "AUTO"   -> auto-detect NVIDIA or AMD
# "NVIDIA" -> manual override
# "AMD"    -> manual override
$GPUProfile = "AUTO"

# --- TOGGLES -------------------------------------------------------------------
$EnableCPU   = $true
$EnableGPU   = $true
$EnableNtfy  = $false
# fipha (github.com/mhwlng/fipha) publishes HWiNFO sensors to Home Assistant
# via MQTT discovery. Optional extra, NOT part of the thermal protection, off
# by default. If you turn it on, it needs its own mqtt.config next to fipha.exe.
$EnableFipha = $false

# --- ntfy ----------------------------------------------------------------------
$NTFY_URL   = "https://ntfy.sh"
$NTFY_TOPIC = "ha-thermalguard-yourname"

# Only needed if your ntfy server requires authentication for publishing.
# Preferred: an access token ("tk_..."), sent as "Authorization: Bearer".
# Alternative: username + password (HTTP Basic). Leave all three empty for
# an open topic. Token wins if both are set.
$NTFY_Token    = ""
$NTFY_User     = ""
$NTFY_Password = ""

# --- UPDATE CHECK ----------------------------------------------------------------
# Checks GitHub's "latest release" API against $ScriptVersion and sends one
# toast + ntfy alert ("update available") when a newer tagged version exists.
# Off by default - set $UpdateCheckRepo to your fork/repo and flip this on.
# Uses the ntfy settings above for the alert; independent of $EnableNtfy so
# the toast still fires even with ntfy off (Send-Alert always tries both).
$EnableUpdateCheck        = $false
$UpdateCheckRepo          = "pol4rfuchs/ThermalGuard-hwinfo64"   # "owner/repo"
$UpdateCheckIntervalHours = 24

# --- UPDATE INSTALL (download, stage, and swap the running script) ----------------
# Requires $EnableUpdateCheck = $true above; this only controls what happens
# once a newer version has already been detected.
#
# $EnableAutoDownload:
#   $false (default) - detection only, as before. No files are touched.
#   $true  - the new version is downloaded and syntax-validated automatically,
#            then staged as "<script>.pending-vX.Y.ps1" next to the running
#            script and a backup of the CURRENT file is made as
#            "<script>.backup-vX.Y.ps1". Nothing is put live yet.
#
# $EnableAutoInstall:
#   $false (default) - a staged update sits there until you approve it, either
#            by running Approve-ThermalGuardUpdate.ps1 (recommended - see
#            that file's own header) or by manually renaming the .pending
#            file over the live one yourself.
#   $true  - the staged update is swapped in and the process restarts itself
#            automatically, no human step in between. Only meaningful
#            combined with $EnableAutoDownload = $true. NOT recommended for
#            a script whose job is to shut your PC down on overheat - see
#            the README section on update safety before enabling this.
#
# Regardless of these two flags, an update is never staged or installed
# while any sensor is currently in an active Stage 2/3 critical state (see
# $script:AnyStageCriticalActive further down) - overheat handling always
# takes priority over updating itself.
$EnableAutoDownload = $false
$EnableAutoInstall  = $false

# Integrity check of the downloaded script. The release must carry a SHA-256
# for the script: either an asset named "<script>.sha256" (contents: the hash,
# optionally followed by the file name) or a "SHA256SUMS" asset in the usual
# "<hash>  <file>" format.
#   $true (default) - no verifiable hash means the update is NOT staged.
#   $false          - an update without hash may still be staged, but it is
#                     marked UNVERIFIED and is NEVER auto-installed, even
#                     with $EnableAutoInstall = $true (manual approval only).
# Note: the hash comes from the same release as the file, so it protects
# against a corrupted or tampered download, not against a compromised repo
# or maintainer account.
$UpdateRequireHash = $true

# How many backup generations to keep as "<script>.backup-vX.Y.ps1" files
# next to the live script. Oldest beyond this count are deleted automatically
# after a new backup is made. Set to 0 to keep only the single most recent
# backup no history beyond "last known good".
$UpdateBackupsToKeep = 3

# After an auto-install swap, the new process must reach its first
# successful sensor poll within this many seconds, or the watchdog
# considers the update a failure and rolls back to the pre-update backup
# automatically (see Invoke-Watchdog's rollback check).
$UpdateHealthCheckTimeoutSec = 90

# --- ALL-TEMPS OVERVIEW REPORT ---------------------------------------------------
# Independent of the 4 monitored sensors above (CPU/GPU/Hotspot/Fan): this scans
# EVERY temperature reading HWiNFO reports (all cores, VRM/chipset/SSD/mainboard/
# RAM/etc. sensors it exposes) and sends one summary of what's currently in
# alert state. Sent once at script start, then again only when the SET of
# sensors in alert state changes - not on every poll, to avoid spam.
#
# Two categories, each with its own TRACK and REPORT threshold:
#   - CPU/GPU runs hotter under normal load, so its thresholds are higher.
#   - Mainboard/RAM sensors sitting well below their normal operating range
#     even at 55 C is already noteworthy, so their thresholds are lower.
# Anything that matches neither pattern (SSD, generic VRM, etc.) falls back
# to the CPU/GPU thresholds, so nothing that used to be covered by the old
# single-threshold version silently drops out of the report.
#
# TRACK vs REPORT is hysteresis, not two separate features: an alert fires
# once a sensor crosses its REPORT threshold, but it stays "in alert" (and
# won't send a "back to normal" message) until it drops back below the
# lower TRACK threshold. Without this, a value hovering right at the report
# line (e.g. 74/76/74/76 C) would flip alert/clear/alert every single poll -
# exactly the toast/ntfy spam this is meant to avoid.
$EnableAllTempsReport = $true

$AllTempsTrackThreshold_CpuGpu  = 60
$AllTempsReportThreshold_CpuGpu = 75

$AllTempsTrackThreshold_Board   = 50
$AllTempsReportThreshold_Board  = 55

# Label pattern that routes a reading to the CPU/GPU thresholds. Checked
# first, so "GPU Memory Junction Temperature" (contains "Memory") correctly
# lands here and not in the board/RAM bucket below.
$CpuGpuLabelPattern   = '(?i)(\bcpu\b|\bgpu\b)'

# Label pattern that routes a reading to the mainboard/RAM thresholds. Not
# yet confirmed against a real json.json dump showing actual mainboard/RAM
# sensor labels (that varies a lot by motherboard vendor) - adjust this
# regex if your board's sensors don't get picked up here. Common candidates
# covered: "Motherboard"/"Mainboard", "System" (many boards label their main
# board-area sensor this way), "PCH" (chipset), "Chipset", "DIMM", "RAM",
# "Memory" (but GPU Memory Junction is excluded by the CPU/GPU check above
# running first).
$BoardRamLabelPattern = '(?i)(mainboard|motherboard|\bsystem\b|\bpch\b|chipset|dimm|\bram\b|memory)'

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

# Unit filter for the DEDICATED CPU/GPU temperature sensors (hard filter, see
# Find-SensorValueSingle): a reading whose unit is not a temperature is never
# used as one, e.g. "CPU Package" must not resolve to "CPU Package Power" (W).
# Deliberately looser than $TempUnitPattern above: it accepts up to 3 non-space
# characters before the C, so it still matches when the degree sign arrives
# garbled by an encoding mismatch (e.g. "?C" or a two-character mojibake), but
# it still rejects W, V, A, RPM, MHz, %, MB, Yes/No and so on.
$DedicatedTempUnitPattern = '(?i)^\s*(deg\s*c|\S{0,3}c)\s*$'

# --- THRESHOLDS ------------------------------------------------------------
# Two ways to set CPU/GPU Warn+Crit, pick one:
#
#   A) RECOMMENDED - fill in $CPU_Tjmax / $GPU_MaxTempSpec below with the ONE
#      number from your own chip's official datasheet (CPU Tjmax) / GPU
#      manufacturer spec page (max GPU temp). Warn/Crit get computed
#      automatically using the margins right below - no need to guess two
#      derived numbers from a generic reference table.
#   B) Leave both $null (default) and set $CPU_WarnTemp/$CPU_CritTemp/
#      $GPU_WarnTemp/$GPU_CritTemp yourself, further down - full manual
#      control, e.g. if you don't have/trust an exact spec number. This is
#      also what keeps existing configs from before this feature unchanged.
$CPU_Tjmax       = $null   # e.g. 90 for a Ryzen 7 5800X3D - see your CPU's datasheet
$GPU_MaxTempSpec = $null   # official max GPU temp from the manufacturer's spec page

$CPU_WarnMarginC = 10   # Warn = Tjmax - this
$CPU_CritMarginC = 3    # Crit = Tjmax - this
$GPU_WarnMarginC = 8    # Warn = MaxTempSpec - this
$GPU_CritMarginC = 2    # Crit = MaxTempSpec - this

# Hardware basis for the manual fallback values below: AMD Ryzen 7 5800X3D
# has a Tjmax (hardware throttle point) of 90 C, and this repo's RTX 5070 Ti
# has an official max GPU temp of 88 C - same numbers $CPU_Tjmax /
# $GPU_MaxTempSpec above would produce if you filled them in instead. A
# previous default Crit value of 91 C was ABOVE the 5800X3D's 90 C Tjmax,
# meaning the hardware would already be throttling itself before this
# script's own "critical" stage ever triggered (report finding, hardware
# limits section) - these fallbacks leave a safety margin under the real
# throttle point instead of guessing a round number.
$CPU_WarnTemp = if ($CPU_Tjmax) { $CPU_Tjmax - $CPU_WarnMarginC } else { 80 }
$CPU_CritTemp = if ($CPU_Tjmax) { $CPU_Tjmax - $CPU_CritMarginC } else { 87 }
$GPU_WarnTemp = if ($GPU_MaxTempSpec) { $GPU_MaxTempSpec - $GPU_WarnMarginC } else { 80 }
$GPU_CritTemp = if ($GPU_MaxTempSpec) { $GPU_MaxTempSpec - $GPU_CritMarginC } else { 86 }

$GPU_HotspotWarn = 95    # AMD hotspot only, typical AMD GPU Tjmax ~110 C
$GPU_HotspotCrit = 105
$GPU_FanWarnRPM  = 300
$GPU_FanCritRPM  = 0
$GPULoadThreshold = 50
# Fan hard-stop / fan warning only count while the GPU is actually warm. Cards
# with a zero-RPM mode stop their fans ON PURPOSE when cool, even at 50% load,
# so "0 RPM under load" alone is not a failure. Below this GPU temperature a
# stopped fan is never evaluated (no warning, no Stage 2/3).
$GPU_FanStopMinTempC = 60

# A running Stage 2/3 timer is only reset once the temperature has dropped this
# many degrees BELOW the Crit threshold. Without it a value hovering at the
# line (87.0 / 86.9 / 87.1 ...) reset the timer on every dip below Crit and
# never reached Stage 3.
$CritResetHysteresisC = 2
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

# --- INFO-ALERT DIGEST (RATE LIMIT) ---------------------------------------------
# The All-Temps-Report and Perf-Limit checks above are informational, not
# safety-critical (the dedicated CPU/GPU Warn/Crit sensors with their
# Stage2/Stage3 kill/shutdown escalation are separate and NOT affected by
# this - those always fire immediately, on purpose, since delaying a
# "shutdown imminent" notice would defeat the point).
#
# Without rate limiting, a value hovering near a threshold, or several
# different sensors crossing at different times, can produce a toast/ntfy
# message every few minutes indefinitely. Instead, informational alerts are
# queued and sent as a single digest at most once per cooldown window - the
# very first alert still goes out immediately (nothing to wait on yet), but
# any further informational changes within the cooldown get batched into
# the next digest instead of firing individually.
$InfoAlertCooldownMinutes = 45

# --- DATA-LOSS FAIL-SAFE ----------------------------------------------------------
# If the script cannot read a valid CPU/GPU temperature at all (endpoint down,
# HWiNFO crashed, sensor label gone) it is blind. Alerts alone do not protect
# the hardware in that state, so after a grace period it falls back to the same
# two stages as a real overheat: kill the Stage-2 process list, then shut down.
# "Blind" = the primary temperature sensors (CPU Tctl/Tdie if CPU monitoring is
# on, GPU Temperature if GPU monitoring is on) have no valid reading. The
# counter resets as soon as data is back. Normal watchdog restarts of HWiNFO
# take well under the first limit, so they do not trigger this.
# Set $EnableDataLossFailsafe = $false to get the old behavior (alert only).
$EnableDataLossFailsafe = $true
$DataLossStage2Sec      = 180
$DataLossShutdownSec    = 420

# --- TIMING --------------------------------------------------------------------
$PollInterval = 5
$Stage2Delay  = 30
$Stage3Delay  = 90
# Stage 3 starts "shutdown.exe /s /f /t <this>" BEFORE it sends its alert, so a
# hanging notification can never delay the emergency stop. 10 s is the window
# the alert gets to go out; the countdown runs regardless.
$EmergencyShutdownDelaySec = 10
# If the main loop did not complete an iteration for this long (PC suspended and
# resumed, or the process was frozen), the wall-clock based Stage 2/3 timers and
# the data-loss counter are meaningless: they would report minutes of "critical"
# time that nobody measured. They are reset and start fresh. The longest normal
# block in the loop (a watchdog restart) is well under a minute.
$LoopGapResetSec = 180

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

# --- SCHEDULED TASK NAME -----------------------------------------------------
# Must match the -TaskName used in Install-ScheduledTask.ps1 exactly - the
# update installer (Install-ThermalGuardUpdate) stops and restarts this task
# by name during a swap/rollback. Two separate files, so there is no single
# source of truth to enforce this automatically; if you rename the task in
# one place, rename it here too.
$ThermalGuardTaskName = "HWiNFO Thermal Guard"

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
# rule for the RemoteHWInfo port, which blocks OTHER devices from reaching it.
# Windows Firewall does not filter loopback traffic, so this script (and anything
# else on this PC) keeps reading http://localhost:<port>. The flip side: a
# remote reader on another machine (e.g. a Home Assistant host) is blocked too.
# Set this to $false if you need that. Requires admin rights, which this script
# already needs for shutdown.exe.
$EnableFirewallHardening = $true
$RemoteHWInfoPort        = 60000

# DryRun / SimulateTemp: this instance must never touch processes, restart
# anything or update itself - it only evaluates and logs.
if ($DryRun) {
    $EnableWatchdog     = $false
    $EnableUpdateCheck  = $false
    $EnableAutoDownload = $false
    $EnableAutoInstall  = $false
}

# === INTERNAL CONFIGURATION (do not edit) ====================================

# Named mutex that makes the monitoring mode single-instance (see the START block).
$InstanceMutexName = "Global\HWiNFO-ThermalGuard-Instance"

$MissingSensorAlertAfterPolls      = 3
$MissingSensorAlertIntervalMinutes = 30
$EndpointAlertIntervalMinutes      = 15
$LogDir       = "$env:USERPROFILE\HWiNFO-ThermalGuard"
$LogFile      = Join-Path $LogDir "thermalguard.log"
$MaxLogSizeMB = 10
$MaxLogFilesToKeep = 10   # rotated thermalguard_*.log files kept besides the live log

# Written to the log by the main loop on the first poll in which all primary
# temperature sensors (CPU / GPU) have a valid reading. The update installer
# waits for exactly this line (with a timestamp after the restart) before it
# calls an update healthy.
$HealthMarkerText = "HEALTHY: first successful sensor poll"

# === LOGGING (must be defined before anything else can call it) =============

$script:LoggedSensorMatchWarnings = @{}
$script:LoggedImplausibleTemp     = @{}

# Physical plausibility bounds for any temperature reading, used as a
# defense-in-depth check independent of sensor-matching logic - see the
# usage site in the main poll loop for the incident that motivated this.
$TempSanityMinC = -20
$TempSanityMaxC = 150

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
        try {
            $keepLogs = [Math]::Max(1, $MaxLogFilesToKeep)
            Get-ChildItem -Path $LogDir -Filter 'thermalguard_*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $keepLogs |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

# Used by the main loop to contain an unexpected exception in one subsystem
# (watchdog, reports, per-sensor evaluation) so it can never end the whole
# protection loop. Logged at most once per $GuardErrorRepeatMinutes per name,
# so a subsystem that throws on every poll does not flood the log.
$script:GuardErrorLast    = @{}
$GuardErrorRepeatMinutes  = 10

function Write-GuardError {
    param([string]$Name, $ErrorRecord)
    $now  = Get-Date
    $last = $script:GuardErrorLast[$Name]
    if ($last -and (($now - $last).TotalMinutes -lt $GuardErrorRepeatMinutes)) { return }
    $script:GuardErrorLast[$Name] = $now
    $where = ""
    try { $where = " (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))" } catch { }
    Write-Log "Subsystem '$Name' threw$where - contained, monitoring loop continues: $($ErrorRecord.Exception.Message)" "ERROR"
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
            Write-Log "Firewall        [OK] Inbound block rule created for port $RemoteHWInfoPort (blocks other devices, localhost is unaffected)"
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

# Installer-only mode never reads sensors, so GPU detection (and its hard exit
# when no GPU is found) must not be able to block an update or a rollback.
if ($InstallPendingUpdate -and $GPUProfile -eq "AUTO") { $GPUProfile = "NVIDIA" }

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
        # RTX 50 cards report a second fan. Optional + armed-after-spinning,
        # see the "GPU Fan 2" sensor entry below.
        Fan2Match        = "GPU Fan2"
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
        # Confirmed live on AMD RX 6800 XT (sensorIndex 11, unit degree-C) via
        # a 120s ThermalGuard-SensorDump.txt sample - same label as on NVIDIA.
        MemJunctionMatch = "GPU Memory Junction Temperature"
        MemJunctionWarn  = $GPU_MemJunctionWarn
        MemJunctionCrit  = $GPU_MemJunctionCrit
        # Confirmed live on AMD RX 6800 XT (sensorIndex 11, unit W) via the
        # same sample. RDNA2 exposes this as "Total Graphics Power (TGP)"
        # rather than NVIDIA's "GPU Power" label.
        PowerMatch       = "Total Graphics Power (TGP)"
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
        # Fallback chain, tried in order until one resolves. "CPU (Tctl/Tdie)"
        # is AMD Ryzen-specific and confirmed working; the rest are common
        # generic labels HWiNFO uses on Intel CPUs, NOT yet confirmed against
        # a real Intel sensor dump (see the "Sensor data" issue template -
        # this is exactly what it's for). Adjust/reorder once confirmed.
        SensorMatch   = @(
            "CPU (Tctl/Tdie)"
            "CPU Package"
            "CPU Package Temperature"
            "CPU Die"
            "CPU Core Max"
        )
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
    if ($p.Fan2Match) {
        # Optional: not every card has (or reports) a second fan, so a missing
        # reading is no alert. Armed-after-spinning: it is only evaluated once
        # it has been seen above 0 RPM in this run, so a phantom 0 RPM reading
        # on a card without a real second fan can never trigger Stage 2/3.
        $Sensors += @{
            Name = "GPU Fan 2"; SensorMatch = $p.Fan2Match
            WarnThreshold = $p.FanWarn; CritThreshold = $p.FanCrit
            Type = "fan"; Group = "GPU"
            PreferredSensorIndex = $script:DetectedGPUSensorIndex
            Optional = $true
        }
    }
}

# Labels already covered by the dedicated per-sensor Warn/Crit timers above
# (CPU Tctl/Tdie, GPU Temperature, GPU Hotspot, GPU Memory Junction) get
# excluded from the generic All-Temps-Report scan further down. Those four
# already have their own staged Warn -> Crit -> kill -> shutdown escalation
# with proper hysteresis; running them through the generic scan too would
# just mean two different alerts firing for the exact same sensor at two
# different thresholds.
$script:DedicatedTempLabels = @(
    $Sensors | Where-Object { $_.Type -eq "temp" } | ForEach-Object { $_.SensorMatch }
)

# DIAGNOSTIC: dumps the exact type and content of each sensor's SensorMatch
# right after construction. Added after a production incident where a GPU
# sensor's SensorMatch was somehow reduced to a single character ('G') by
# the time it reached the lookup code, causing a false-positive emergency
# shutdown. This makes it possible to tell whether the corruption already
# exists at config time (bug is in $GPUProfiles/$Sensors construction
# above) or only appears later (bug is in Find-SensorValue/self-test).
# Safe to remove once the root cause is confirmed and fixed.
foreach ($diagSensor in $Sensors) {
    $smType = if ($null -eq $diagSensor.SensorMatch) { "NULL" } else { $diagSensor.SensorMatch.GetType().Name }
    $smDisplay = if ($diagSensor.SensorMatch -is [array]) {
        "[" + ($diagSensor.SensorMatch -join ' | ') + "]"
    } else {
        "'$($diagSensor.SensorMatch)' (length $(([string]$diagSensor.SensorMatch).Length))"
    }
    Write-Log "DIAG: Sensor '$($diagSensor.Name)' SensorMatch type=$smType value=$smDisplay"
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
        if ($r.hwinfo -and $r.hwinfo.readings -and $r.hwinfo.readings.Count -gt 0) {
            Write-Log "HTTP Endpoint   [OK] $HWiNFO_URL ($($r.hwinfo.readingCount) readings)"
        } else {
            # Reachable, but no HWiNFO readings. RemoteHWInfo runs with
            # -gpuz=0 -afterburner=0, so its GPUZShMem/MAHMSharedMemory
            # mappings are ALWAYS null by design and irrelevant here - an
            # empty/near-empty response means HWiNFO's own Shared Memory
            # Support is off, not a "Sensors-only mode" issue.
            Write-Log "HTTP Endpoint   [ERROR] Reachable but no HWiNFO readings" "ERROR"
            Write-Log "  Hint: HWiNFO64 -> Settings -> enable 'Shared Memory Support', then restart HWiNFO64." "WARN"
            Write-Log "  (GPU-Z/Afterburner shared memory is intentionally off via -gpuz=0 -afterburner=0, that is not the cause.)" "WARN"
            $ok = $false
        }
    } catch {
        Write-Log "HTTP Endpoint   [ERROR] Not reachable: $HWiNFO_URL" "ERROR"
        Write-Log "  Hint: RemoteHWInfo may still be starting, or Sensors-only mode isn't active yet." "WARN"
        $ok = $false
    }

    if ($EnableNtfy) {
        # Retry with backoff: a brief network hiccup right at process start
        # (DNS cache miss, resolver timeout, reverse-proxy not warmed up yet)
        # previously meant a single failed attempt here permanently logged
        # ntfy as unreachable for that whole run, even though the exact same
        # request would have succeeded seconds later.
        $ntfyOk = $false
        $ntfyDelays = @(2, 5, 10)
        for ($attempt = 0; $attempt -le $ntfyDelays.Count; $attempt++) {
            try {
                Invoke-RestMethod -Uri "$NTFY_URL/$NTFY_TOPIC" -Method Post -Body "ThermalGuard started" `
                    -Headers (Get-NtfyHeaders -Title "ThermalGuard started" -Tags "white_check_mark") `
                    -TimeoutSec 5 | Out-Null
                Write-Log "ntfy            [OK] $NTFY_URL/$NTFY_TOPIC"
                $ntfyOk = $true
                break
            } catch {
                if ($attempt -lt $ntfyDelays.Count) {
                    $delay = $ntfyDelays[$attempt]
                    Write-Log "ntfy            [WARN] Attempt $($attempt + 1) failed, retrying in ${delay}s..." "WARN"
                    Start-Sleep -Seconds $delay
                }
            }
        }
        if (-not $ntfyOk) {
            Write-Log "ntfy            [WARN] Not reachable after $($ntfyDelays.Count + 1) attempts" "WARN"
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

function Get-NtfyHeaders {
    # One place for all ntfy headers, including optional authentication.
    # Token (Bearer) wins over user/password (Basic); both empty = open topic.
    param([string]$Title, [string]$Priority = $null, [string]$Tags = $null)

    $h = @{ "Title" = $Title }
    if ($Priority) { $h["Priority"] = $Priority }
    if ($Tags)     { $h["Tags"]     = $Tags }
    if ($NTFY_Token) {
        $h["Authorization"] = "Bearer $NTFY_Token"
    } elseif ($NTFY_User -and $NTFY_Password) {
        $pair = [System.Text.Encoding]::UTF8.GetBytes("${NTFY_User}:${NTFY_Password}")
        $h["Authorization"] = "Basic " + [Convert]::ToBase64String($pair)
    }
    return $h
}

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
            -Headers (Get-NtfyHeaders -Title $Title -Priority $Priority -Tags "warning,thermometer") `
            -TimeoutSec 5 | Out-Null
        Write-Log "ntfy sent: $Title"
    } catch {
        Write-Log "ntfy failed: $_" "WARN"
    }
}

# '' (not $null): "nothing in alert state" is the starting point, so a first poll
# with no hot sensor stays silent instead of announcing "back to normal".
$script:LastOverThresholdKey = ''
$script:TempAlertState       = @{}

function Get-TempCategory {
    param([string]$Label)

    if ($Label -match $CpuGpuLabelPattern) {
        return [PSCustomObject]@{
            Name  = "CPU/GPU"
            Track = $AllTempsTrackThreshold_CpuGpu
            Report = $AllTempsReportThreshold_CpuGpu
        }
    }
    if ($Label -match $BoardRamLabelPattern) {
        return [PSCustomObject]@{
            Name  = "Board/RAM"
            Track = $AllTempsTrackThreshold_Board
            Report = $AllTempsReportThreshold_Board
        }
    }
    # Fallback for anything unclassified (SSD, generic VRM, etc.) - use the
    # CPU/GPU thresholds as the generic default rather than dropping these
    # readings from the report entirely.
    return [PSCustomObject]@{
        Name  = "Other"
        Track = $AllTempsTrackThreshold_CpuGpu
        Report = $AllTempsReportThreshold_CpuGpu
    }
}

function Get-AllTempsInAlertState {
    param($SensorData)

    $seen   = @{}
    $result = @()
    foreach ($reading in $SensorData.readings) {
        if ([string]$reading.unit -notmatch $TempUnitPattern) { continue }
        $val = $null
        # IMPORTANT: the simple 2-arg TryParse overload uses the current
        # Windows culture and allows thousands-grouping. On de-AT/de-DE
        # systems "." is the thousands separator, so a JSON value like
        # "61.625000" gets misread as an invalidly-grouped thousands number
        # and TryParse silently returns false - meaning every reading with
        # a fractional value got skipped here, regardless of its actual
        # magnitude. JSON numbers are always period-decimal by spec, so
        # force InvariantCulture + Float-only (no grouping) explicitly.
        if (-not [double]::TryParse(
                [string]$reading.value,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$val)) { continue }
        if ($val -lt $TempSanityMinC -or $val -gt $TempSanityMaxC) {
            # Same defense-in-depth as the dedicated sensor loop: never
            # treat an implausible number as a real temperature.
            continue
        }

        # Same dedup key as elsewhere: sensorIndex+readingId identifies one
        # physical reading, HWiNFO/RemoteHWInfo can list it twice.
        $dedupKey = "$($reading.sensorIndex)|$($reading.readingId)"
        if ($seen.ContainsKey($dedupKey)) { continue }
        $seen[$dedupKey] = $true

        # Already handled by the dedicated Warn/Crit system with its own
        # (lower, more conservative) thresholds and staged escalation -
        # skip here so it doesn't also fire through the generic report.
        if ($script:DedicatedTempLabels -contains $reading.labelOriginal) { continue }

        $label = if ($reading.labelUser) { $reading.labelUser } else { $reading.labelOriginal }
        $cat = Get-TempCategory -Label $label

        # Hysteresis: enter alert state at the (higher) report threshold,
        # only leave alert state once back below the (lower) track
        # threshold. Prevents flapping when a value hovers right around
        # the report line.
        $wasAlert = $script:TempAlertState.ContainsKey($dedupKey) -and $script:TempAlertState[$dedupKey]
        $isAlert = $wasAlert
        if (-not $wasAlert -and $val -ge $cat.Report) {
            $isAlert = $true
        } elseif ($wasAlert -and $val -lt $cat.Track) {
            $isAlert = $false
        }
        $script:TempAlertState[$dedupKey] = $isAlert

        if ($isAlert) {
            $result += [PSCustomObject]@{
                Label    = $label
                Value    = $val
                Category = $cat.Name
            }
        }
    }
    return $result | Sort-Object Category, Label
}

function Resolve-GPUSensorIndex {
    # $script:DetectedGPUSensorIndex used to be set only by the HWiNFO fallback
    # of GPU detection. With the normal WMI detection it stayed $null, so every
    # "sensorIndex -eq <index>" filter (Performance Limit flags, GPU power line)
    # never matched and, on iGPU + dGPU systems, the dedicated GPU sensors could
    # land on the wrong device. This works the index out from the live sensor
    # data on the first successful polls: the device that reports the profile's
    # GPU temperature label. With several candidates the detected GPU name picks
    # the right one. Idempotent; does nothing once an index is known.
    param($SensorData)

    if (-not $EnableGPU) { return }
    if ($null -ne $script:DetectedGPUSensorIndex) { return }

    $tempMatch  = $GPUProfiles[$GPUProfile].TempMatch
    $candidates = @($SensorData.readings | Where-Object {
        $_.labelOriginal -eq $tempMatch -and [string]$_.unit -match $DedicatedTempUnitPattern
    })
    $indexes = @($candidates | ForEach-Object { $_.sensorIndex } | Sort-Object -Unique)
    if ($indexes.Count -eq 0) { return }

    $chosen = $null
    if ($indexes.Count -eq 1) {
        $chosen = $indexes[0]
    } else {
        $name = [string]$script:DetectedGPUName
        if ($name) {
            foreach ($idx in $indexes) {
                $entry = $SensorData.sensors | Where-Object { $_.entryIndex -eq $idx } | Select-Object -First 1
                $sn    = if ($entry) { [string]$entry.sensorNameOriginal } else { "" }
                if ($sn -and $sn.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $chosen = $idx; break }
            }
        }
        if ($null -eq $chosen) {
            $chosen = $indexes[0]
            Write-Log "GPU sensor index: $($indexes.Count) devices report '$tempMatch' (sensorIndex $($indexes -join ', ')) and none matches the detected GPU '$name' by name - using sensorIndex $chosen" "WARN"
        }
    }

    $script:DetectedGPUSensorIndex = $chosen
    foreach ($s in $Sensors) {
        if ($s.Group -eq "GPU") { $s.PreferredSensorIndex = $chosen }
    }
    Write-Log "GPU sensor index: sensorIndex $chosen resolved from live sensor data ($($indexes.Count) candidate device(s))"
}

function Find-GPUReading {
    # One reading by exact label, restricted to the GPU's own device when its
    # sensorIndex is known (falls back to the first label match when it is not).
    param($SensorData, [string]$Label)

    $m = @($SensorData.readings | Where-Object { $_.labelOriginal -eq $Label })
    if ($null -ne $script:DetectedGPUSensorIndex) {
        $m = @($m | Where-Object { $_.sensorIndex -eq $script:DetectedGPUSensorIndex })
    }
    return ($m | Select-Object -First 1)
}

function Get-CurrentGPUPowerLine {
    param($SensorData)

    if (-not $EnableGPU) { return $null }
    $powerMatch = $GPUProfiles[$GPUProfile].PowerMatch
    if (-not $powerMatch) { return $null }

    $reading = Find-GPUReading -SensorData $SensorData -Label $powerMatch
    if (-not $reading) { return $null }

    return "GPU Power: $($reading.value) W"

}

$script:PendingInfoLines    = @()
$script:LastInfoAlertSentAt = $null

function Queue-InfoAlert {
    param([string]$Line)
    $script:PendingInfoLines += $Line
    Write-Log "Info-alert queued for next digest: $Line"
}

function Invoke-InfoAlertDigestFlush {
    if ($script:PendingInfoLines.Count -eq 0) { return }

    $elapsedMin = if ($script:LastInfoAlertSentAt) {
        ((Get-Date) - $script:LastInfoAlertSentAt).TotalMinutes
    } else {
        # Never sent one yet - go out immediately, nothing to wait on.
        [double]::MaxValue
    }
    if ($elapsedMin -lt $InfoAlertCooldownMinutes) { return }

    $count = $script:PendingInfoLines.Count
    $body  = $script:PendingInfoLines -join "`n"
    Write-Log "Info-alert digest sent: $count item(s) -> $($script:PendingInfoLines -join ' | ')"
    Send-Alert -Title "Status update ($count change$(if ($count -ne 1) {'s'}))" -Body $body -Priority "default"
    $script:PendingInfoLines    = @()
    $script:LastInfoAlertSentAt = Get-Date
}

function Invoke-AllTempsReportCheck {
    param($SensorData)

    if (-not $EnableAllTempsReport) { return }

    $alertList = Get-AllTempsInAlertState -SensorData $SensorData
    # The key is the SET of sensors in alert state, NOT their values. HWiNFO
    # values change on nearly every poll (61.625, 61.75, ...), so a key that
    # contained them would differ every 5 s while any sensor sits above its
    # report threshold and queue one info line per poll, which then arrived as
    # a digest with hundreds of lines.
    $currentKey = ($alertList | ForEach-Object { [string]$_.Label }) -join ';'

    if ($currentKey -eq $script:LastOverThresholdKey) { return }
    $script:LastOverThresholdKey = $currentKey

    if ($alertList.Count -eq 0) {
        Write-Log "All-temps report: back under thresholds on all sensors"
        Queue-InfoAlert -Line "Temps back to normal: no sensor above its report threshold anymore."
        return
    }

    # @(...) on purpose: with exactly one alert the pipeline yields a plain string,
    # and "$lines += $powerLine" below would then glue the two texts together.
    $lines = @($alertList | ForEach-Object { "[$($_.Category)] $($_.Label): $($_.Value) C" })
    $powerLine = Get-CurrentGPUPowerLine -SensorData $SensorData
    if ($powerLine) { $lines += $powerLine }
    $body  = $lines -join "; "
    Write-Log "All-temps report: $($alertList.Count) sensor(s) over threshold -> $($lines -join ' | ')"
    Queue-InfoAlert -Line "Temps over threshold ($($alertList.Count)): $body"
}

$script:PerfLimitLastState = @{}

function Invoke-PerfLimitCheck {
    param($SensorData)

    if (-not $EnablePerfLimitAlerts) { return }
    if (-not $EnableGPU) { return }

    foreach ($flagName in $PerfLimitFlagsToWatch) {
        $reading = Find-GPUReading -SensorData $SensorData -Label $flagName
        if (-not $reading) { continue }

        # Invariant-culture parse instead of a [double] cast: an unparsable
        # value skips this flag for the poll instead of throwing.
        $flagValue = 0.0
        if (-not [double]::TryParse([string]$reading.value, [System.Globalization.NumberStyles]::Float,
                                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$flagValue)) { continue }
        $isActive = ($flagValue -eq 1)
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
            Queue-InfoAlert -Line "GPU throttle active: $flagName"
        } else {
            Write-Log "$flagName cleared"
            Queue-InfoAlert -Line "GPU throttle cleared: $flagName"
        }
    }
}

function Send-Alert {
    param([string]$Title, [string]$Body, [string]$Priority = "high")
    if ($DryRun) { $Title = "[DRYRUN] $Title" }
    Send-Toast -Title $Title -Body $Body
    Send-Ntfy  -Title $Title -Body $Body -Priority $Priority
}

# === UPDATE CHECK ==============================================================
# Report finding: users had no way to know a newer ThermalGuard version was
# out short of manually checking GitHub. This queries the "latest release"
# API (drafts/prereleases excluded by GitHub itself), compares the tag
# against $ScriptVersion, and alerts once per new version - not once per
# check interval, so it doesn't re-nag every 24h while the user is on the
# same outdated version.

$script:LastUpdateCheck          = $null
$script:LastAlertedUpdateVersion = $null
$script:LastStagedUpdateVersion  = $null
$script:AnyStageCriticalActive   = $false

function ConvertTo-SafeAlertText {
    # Toast/ntfy bodies are single-line-ish and length-limited in practice;
    # a raw multi-paragraph GitHub release body would either get truncated
    # ungracefully by the notification system or blow past ntfy's server
    # limits. This collapses it to something readable in a notification and
    # points at the full release page for the rest.
    param([string]$Text, [int]$MaxLength = 300)
    if (-not $Text) { return "" }
    $oneLine = ($Text -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
    if ($oneLine.Length -gt $MaxLength) {
        $oneLine = $oneLine.Substring(0, $MaxLength) + "..."
    }
    return $oneLine
}

function Invoke-UpdateCheck {
    if (-not $EnableUpdateCheck) { return }

    # Overheat handling always outranks updating the very script doing the
    # handling - never even check, let alone stage or install, while a
    # sensor is mid-way through its Stage 2/3 timer.
    if ($script:AnyStageCriticalActive) {
        return
    }

    $now = Get-Date
    if ($script:LastUpdateCheck -and (($now - $script:LastUpdateCheck).TotalHours -lt $UpdateCheckIntervalHours)) {
        return
    }
    $script:LastUpdateCheck = $now

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$UpdateCheckRepo/releases/latest" `
            -Headers @{ "User-Agent" = "HWiNFO-ThermalGuard" } -TimeoutSec 10 -ErrorAction Stop
    } catch {
        Write-Log "Update check    [WARN] Could not reach GitHub: $_" "WARN"
        return
    }

    # Strip a leading "v" and any "-suffix" (e.g. "-test" prereleases, which
    # /releases/latest shouldn't return anyway, but be defensive) before
    # parsing as a [version] so "v1.48" and "1.48" both work.
    $remoteTag        = [string]$release.tag_name
    $remoteVersionStr = ($remoteTag -replace '^v', '') -replace '-.*$', ''

    try {
        $remoteVersion = [version]$remoteVersionStr
        $localVersion  = [version]$ScriptVersion
    } catch {
        Write-Log "Update check    [WARN] Could not parse version (local='$ScriptVersion', remote tag='$remoteTag')" "WARN"
        return
    }

    if ($remoteVersion -le $localVersion) {
        Write-Log "Update check    [OK] Running latest ($ScriptVersion), GitHub latest is $remoteTag"
        return
    }

    $changelog = ConvertTo-SafeAlertText -Text ([string]$release.body)

    if ($script:LastAlertedUpdateVersion -ne $remoteTag) {
        $script:LastAlertedUpdateVersion = $remoteTag
        Write-Log "Update check    [INFO] New version available: $remoteTag (running $ScriptVersion)" "WARN"
        if ($changelog) {
            Write-Log "Update check    Changelog: $changelog"
        }
        $body = if ($changelog) { "$remoteTag is out, you're on $ScriptVersion. $changelog" } `
                else            { "$remoteTag is out, you're on $ScriptVersion." }
        Send-Alert -Title "ThermalGuard update available" `
            -Body "$body https://github.com/$UpdateCheckRepo/releases/latest" `
            -Priority "default"
    }

    if (-not $EnableAutoDownload) { return }
    if ($script:LastStagedUpdateVersion -eq $remoteTag) {
        # Already staged (or already tried and failed to stage) this exact
        # version - don't re-download every check interval.
        return
    }

    $handled = Invoke-StageUpdate -Release $release -RemoteTag $remoteTag -RemoteVersion $remoteVersion |
               Select-Object -Last 1
    # Only remember the version when it was dealt with for good (staged or
    # definitively rejected). A transient failure such as a dropped download
    # is retried at the next check instead of being blocked until restart.
    if ($handled -eq $true) { $script:LastStagedUpdateVersion = $remoteTag }
}

# === UPDATE INSTALL (staging, syntax validation, backup, swap, rollback) ======
# Everything below this point is only reachable when $EnableAutoDownload
# and/or $EnableAutoInstall are turned on, or when this script is invoked
# directly with -InstallPendingUpdate (see Approve-ThermalGuardUpdate.ps1).
# Off by default; see the config block near the top of this file.

function Get-ThermalGuardUpdatePaths {
    param([string]$Version, [string]$BackupVersion)

    $livePath = $PSCommandPath
    if (-not $livePath) {
        # Should not happen in normal operation (this script is always
        # launched via -File from Start-HWiNFO-Remote.bat / the Scheduled
        # Task), but fall back to the configured ToolsDir install location
        # rather than crash if it's ever dot-sourced or pasted interactively.
        $livePath = Join-Path $ToolsDir "HWiNFO-ThermalGuard\HWiNFO-ThermalGuard.ps1"
    }

    $dir      = Split-Path $livePath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($livePath)

    $result = @{
        LivePath = $livePath
        Dir      = $dir
        BaseName = $baseName
    }
    if ($Version) {
        $result.PendingPath = Join-Path $dir "$baseName.pending-v$Version.ps1"
    }
    if ($BackupVersion) {
        # Named after the version the backed-up file CONTAINS (the one live
        # right now), not after the version that replaces it. It used to be
        # the other way round, which made the second update roll back to the
        # wrong file.
        $result.BackupPath = Join-Path $dir "$baseName.backup-v$BackupVersion.ps1"
    }
    return $result
}

function Test-ScriptSyntaxValid {
    # Parses (but never executes) the given file using the same parser
    # PowerShell itself uses to load a script, surfacing any syntax error
    # (unbalanced braces/quotes, the PS7 "$var:" scope-operator collision
    # class of bug seen earlier in this project's history, etc.) before the
    # file is ever put in the position the live, running script occupies.
    param([string]$Path)

    $tokens = $null
    $errors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    } catch {
        Write-Log "Update install  [ERROR] Parser threw while validating $Path : $_" "ERROR"
        return $false
    }

    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Log "Update install  [ERROR] Syntax error in staged update: $($e.Message) (line $($e.Extent.StartLineNumber))" "ERROR"
        }
        return $false
    }
    return $true
}

function Get-VersionFromFileName {
    # "<base>.pending-v1.51.ps1" / "<base>.backup-v1.50.ps1" -> [version] 1.51 / 1.50.
    # Unparsable names sort last (0.0).
    param([string]$Name)
    if ($Name -match '-v([\d\.]+?)\.ps1$') {
        try { return [version]$matches[1] } catch { }
    }
    return [version]'0.0'
}

function Get-SortedVersionedFiles {
    # Newest version first. Sorted by the version in the file NAME, not by
    # LastWriteTime: Copy-Item keeps the source file's timestamp, so a fresh
    # backup of an old file would otherwise look "old".
    param([string]$Pattern)
    $files = @(Get-ChildItem -Path $Pattern -ErrorAction SilentlyContinue)
    return @($files | Sort-Object -Property @{ Expression = { Get-VersionFromFileName $_.Name }; Descending = $true })
}

function Get-ExpectedUpdateHash {
    # Looks for a SHA-256 for $FileName among the release assets:
    #   "<file>.sha256" / "<file>.sha256.txt"  -> first 64-hex string in it
    #   "SHA256SUMS" / "SHA256SUMS.txt"        -> line "<hash>  <file>"
    # Returns the lowercase hash, or $null if no usable one was found.
    param($Release, [string]$FileName)

    $names = @("$FileName.sha256", "$FileName.sha256.txt", "SHA256SUMS", "SHA256SUMS.txt", "sha256sums.txt")
    foreach ($n in $names) {
        $asset = $Release.assets | Where-Object { $_.name -ieq $n } | Select-Object -First 1
        if (-not $asset) { continue }

        try {
            $resp    = Invoke-WebRequest -Uri $asset.browser_download_url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $content = $resp.Content
            if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
            $content = [string]$content
        } catch {
            Write-Log "Update install  [WARN] Could not download hash asset '$n': $_" "WARN"
            continue
        }

        $perFile = ($n -ieq "$FileName.sha256") -or ($n -ieq "$FileName.sha256.txt")
        foreach ($line in ($content -split '\r?\n')) {
            if ($perFile) {
                if ($line -match '(?i)\b([a-f0-9]{64})\b') { return $matches[1].ToLowerInvariant() }
            } elseif ($line -match '(?i)^\s*([a-f0-9]{64})\s+\*?(.+?)\s*$') {
                $hashPart = $matches[1]
                $namePart = $matches[2]
                if ((Split-Path $namePart -Leaf) -ieq $FileName) { return $hashPart.ToLowerInvariant() }
            }
        }
    }
    return $null
}

function Set-GuardTaskEnabled {
    # Disabling the task while files are swapped keeps its repetition trigger
    # from launching a half-updated guard in the middle of the swap. No-op
    # when no scheduled task exists (shell:startup setups).
    #
    # $script:GuardTaskDisabledByInstaller remembers that THIS process disabled
    # it, so the installer's "finally" can put it back even when the install
    # aborts half way (an exception between disable and enable used to leave the
    # task disabled for good: no protection and no self-heal). A task the user
    # had disabled themselves is never enabled by this.
    param([bool]$Enabled)
    try {
        $task = Get-ScheduledTask -TaskName $ThermalGuardTaskName -ErrorAction SilentlyContinue
        if (-not $task) { return }
        if ($Enabled) {
            Enable-ScheduledTask  -TaskName $ThermalGuardTaskName -ErrorAction Stop | Out-Null
            $script:GuardTaskDisabledByInstaller = $false
        } else {
            Disable-ScheduledTask -TaskName $ThermalGuardTaskName -ErrorAction Stop | Out-Null
            $script:GuardTaskDisabledByInstaller = $true
        }
    } catch {
        Write-Log "Update install  [WARN] Could not $(if ($Enabled) {'enable'} else {'disable'}) scheduled task '$ThermalGuardTaskName': $_" "WARN"
    }
}

$script:GuardTaskDisabledByInstaller = $false

function Test-IsGuardProcess {
    # True for a PowerShell process that runs the ThermalGuard script via -File.
    # The process NAME is part of the test: matching on the command line alone
    # also hit any other process that merely mentions the script name (an editor,
    # a terminal, a monitoring tool).
    param([string]$Name, [string]$CommandLine)
    return ($Name -match '(?i)^(pwsh|powershell)(\.exe)?$') -and
           ($CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1')
}

function Stop-RunningGuardProcesses {
    # Stops every OTHER ThermalGuard monitoring process (never this one).
    try { Stop-ScheduledTask -TaskName $ThermalGuardTaskName -ErrorAction SilentlyContinue } catch { }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and (Test-IsGuardProcess -Name $_.Name -CommandLine $_.CommandLine) } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    Start-Sleep -Seconds 2
}

function Start-GuardAfterSwap {
    # Restarts the guard the way it was started: through the Scheduled Task if
    # it exists, otherwise (shell:startup setups) through the VBS launcher.
    # Throws if neither is available.
    $paths = Get-ThermalGuardUpdatePaths
    $task  = Get-ScheduledTask -TaskName $ThermalGuardTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $ThermalGuardTaskName -ErrorAction Stop
        return
    }
    $vbs = Join-Path $paths.Dir "Start-HWiNFO-Remote.vbs"
    if (-not (Test-Path $vbs)) {
        throw "No scheduled task '$ThermalGuardTaskName' and no launcher at $vbs"
    }
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbs`""
}

function Invoke-StageUpdate {
    # Returns $true when this release version has been dealt with for good
    # (staged, or definitively rejected) and $false when the failure was
    # transient (download) and a later check should simply try again.
    param($Release, [string]$RemoteTag, [version]$RemoteVersion)

    $paths = Get-ThermalGuardUpdatePaths -Version $RemoteVersion.ToString() -BackupVersion $ScriptVersion
    Write-Log "Update install  Staging $RemoteTag ..."

    # A version that already failed its health check once and was rolled back
    # is not staged again (that would be a rollback loop on every restart).
    $failedMarker = Join-Path $paths.Dir "$($paths.BaseName).failed-v$($RemoteVersion.ToString()).txt"
    if (Test-Path $failedMarker) {
        Write-Log "Update install  [WARN] Skipping ${RemoteTag}: it failed its health check on this machine before. Delete $failedMarker to try it again." "WARN"
        return $true
    }

    # Prefer an attached release asset with the exact same filename as the
    # live script; fall back to the raw file at that tag if the release has
    # no attached assets (e.g. GitHub's auto-generated source zip only).
    $liveFileName = Split-Path $paths.LivePath -Leaf
    $asset        = $Release.assets | Where-Object { $_.name -eq $liveFileName } | Select-Object -First 1
    $downloadUrl  = if ($asset) { $asset.browser_download_url } `
                    else        { "https://raw.githubusercontent.com/$UpdateCheckRepo/$RemoteTag/$liveFileName" }

    $tempFile = Join-Path $env:TEMP "thermalguard-update-$RemoteTag.ps1"
    try {
        Write-Log "Update install  Downloading: $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Write-Log "Update install  [ERROR] Download failed: $_" "ERROR"
        Send-Alert -Title "ThermalGuard update download failed" -Body "$RemoteTag could not be downloaded: $_" -Priority "high"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # --- integrity: SHA-256 against the hash published with the release ------
    $actualHash   = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = Get-ExpectedUpdateHash -Release $Release -FileName $liveFileName
    $hashVerified = $false
    if ($expectedHash) {
        if ($actualHash -ne $expectedHash) {
            Write-Log "Update install  [ERROR] SHA-256 mismatch for $RemoteTag (expected $expectedHash, got $actualHash). NOT staging it." "ERROR"
            Send-Alert -Title "ThermalGuard update rejected" `
                -Body "$RemoteTag does not match its published SHA-256 and was not installed. Still running $ScriptVersion." `
                -Priority "urgent"
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            return $true
        }
        $hashVerified = $true
        Write-Log "Update install  SHA-256 verified: $actualHash"
    } elseif ($UpdateRequireHash) {
        Write-Log "Update install  [ERROR] $RemoteTag has no usable SHA-256 asset and `$UpdateRequireHash is on. NOT staging it." "ERROR"
        Send-Alert -Title "ThermalGuard update rejected" `
            -Body "$RemoteTag has no SHA-256 published with the release, so it was not downloaded for install. Still running $ScriptVersion." `
            -Priority "high"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $true
    } else {
        Write-Log "Update install  [WARN] No SHA-256 published for $RemoteTag. Staging it as UNVERIFIED (never auto-installed). SHA-256 of the download: $actualHash" "WARN"
    }

    if (-not (Test-ScriptSyntaxValid -Path $tempFile)) {
        Write-Log "Update install  [ERROR] Downloaded $RemoteTag failed syntax validation, NOT staging it." "ERROR"
        Send-Alert -Title "ThermalGuard update rejected" `
            -Body "$RemoteTag failed syntax validation after download and was not installed. Still running $ScriptVersion." `
            -Priority "high"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $true
    }

    try {
        if (Test-Path $paths.LivePath) {
            Copy-Item -Path $paths.LivePath -Destination $paths.BackupPath -Force -ErrorAction Stop
            Write-Log "Update install  Backed up current v$ScriptVersion to $($paths.BackupPath)"
        }
        # Only one staged update at a time: drop older pending files and their hash sidecars.
        Get-ChildItem -Path (Join-Path $paths.Dir "$($paths.BaseName).pending-v*") -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Move-Item -Path $tempFile -Destination $paths.PendingPath -Force -ErrorAction Stop
        if ($hashVerified) {
            # The installer re-checks the staged file against this right before the swap.
            Set-Content -Path "$($paths.PendingPath).sha256" -Value $actualHash -Encoding ASCII -ErrorAction Stop
        }
        Write-Log "Update install  [OK] Staged $RemoteTag as $($paths.PendingPath)$(if (-not $hashVerified) {' (UNVERIFIED)'})"
    } catch {
        Write-Log "Update install  [ERROR] Could not stage files: $_" "ERROR"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Rotate old backups beyond the configured retention count. 0 would mean
    # "delete everything including the backup just made", so keep at least one.
    try {
        $keepBackups = [Math]::Max(1, $UpdateBackupsToKeep)
        $oldBackups  = Get-SortedVersionedFiles -Pattern (Join-Path $paths.Dir "$($paths.BaseName).backup-v*.ps1") |
                       Select-Object -Skip $keepBackups
        foreach ($old in $oldBackups) {
            Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Update install  Rotated out old backup: $($old.Name)"
        }
    } catch {
        Write-Log "Update install  [WARN] Backup rotation failed (non-fatal): $_" "WARN"
    }

    if ($EnableAutoInstall -and $hashVerified) {
        Write-Log "Update install  EnableAutoInstall is on, launching installer for $RemoteTag ..."
        Send-Alert -Title "ThermalGuard installing update" `
            -Body "$RemoteTag downloaded, hash-verified and validated, installing now. Will roll back automatically if it fails to come up healthy." `
            -Priority "default"
        try {
            Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($paths.LivePath)`" -InstallPendingUpdate" `
                -WindowStyle Hidden
        } catch {
            Write-Log "Update install  [ERROR] Could not launch installer process: $_" "ERROR"
        }
    } elseif ($EnableAutoInstall) {
        Write-Log "Update install  [WARN] EnableAutoInstall is on, but $RemoteTag is UNVERIFIED (no SHA-256). Not installing automatically." "WARN"
        Send-Alert -Title "ThermalGuard update staged (unverified)" `
            -Body "$RemoteTag has no published SHA-256, so it was NOT auto-installed. Check it, then run Approve-ThermalGuardUpdate.ps1." `
            -Priority "default"
    } else {
        Send-Alert -Title "ThermalGuard update staged" `
            -Body "$RemoteTag downloaded$(if ($hashVerified) {', hash-verified'} else {' (UNVERIFIED)'}) and validated. Run Approve-ThermalGuardUpdate.ps1 to install it." `
            -Priority "default"
    }
    return $true
}

function Install-ThermalGuardUpdate {
    # Standalone install routine: verify -> back up -> stop -> swap -> restart
    # -> health check -> rollback-if-unhealthy. Written to run as a SEPARATE
    # process from whatever it replaces, either as a detached child spawned by
    # the currently-running (old, known good) guard, or by hand through
    # Approve-ThermalGuardUpdate.ps1. That separation is what makes the health
    # check and rollback meaningful: a process cannot reliably supervise
    # replacing its own running code and then judge whether that worked.
    $paths = Get-ThermalGuardUpdatePaths

    $pending = Get-SortedVersionedFiles -Pattern (Join-Path $paths.Dir "$($paths.BaseName).pending-v*.ps1") |
               Select-Object -First 1
    if (-not $pending) {
        Write-Log "Update install  [INFO] No staged update found in $($paths.Dir). Nothing to do."
        return
    }

    if ($pending.Name -match '\.pending-v([\d\.]+)\.ps1$') {
        $newVersion = $matches[1]
    } else {
        Write-Log "Update install  [ERROR] Could not parse version out of staged filename: $($pending.Name)" "ERROR"
        return
    }

    try {
        if ([version]$newVersion -le [version]$ScriptVersion) {
            Write-Log "Update install  [WARN] Staged v$newVersion is not newer than the running v$ScriptVersion. Not installing." "WARN"
            return
        }
    } catch {
        Write-Log "Update install  [ERROR] Could not compare versions (staged '$newVersion', running '$ScriptVersion'): $_" "ERROR"
        return
    }

    # --- integrity: staged file must still match the hash it was staged with --
    $sidecar = "$($pending.FullName).sha256"
    if (Test-Path $sidecar) {
        $expected = ([string](Get-Content -Path $sidecar -TotalCount 1 -ErrorAction SilentlyContinue)).Trim().ToLowerInvariant()
        $actual   = (Get-FileHash -Path $pending.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Write-Log "Update install  [ERROR] Staged file $($pending.Name) no longer matches its recorded SHA-256 (expected $expected, got $actual). NOT installing." "ERROR"
            Send-Alert -Title "ThermalGuard update refused" -Body "Staged v$newVersion was modified after download. Not installed." -Priority "urgent"
            return
        }
        Write-Log "Update install  Staged file SHA-256 re-verified."
    } elseif ($UpdateRequireHash) {
        Write-Log "Update install  [ERROR] $($pending.Name) has no .sha256 sidecar and `$UpdateRequireHash is on. NOT installing." "ERROR"
        Write-Log "  -> Create '$($pending.Name).sha256' with the file's SHA-256 yourself, or set `$UpdateRequireHash = `$false." "ERROR"
        Send-Alert -Title "ThermalGuard update refused" -Body "Staged v$newVersion has no recorded SHA-256. Not installed." -Priority "high"
        return
    } else {
        Write-Log "Update install  [WARN] Installing UNVERIFIED staged file $($pending.Name) (no .sha256 sidecar, `$UpdateRequireHash is off)." "WARN"
    }

    if (-not (Test-ScriptSyntaxValid -Path $pending.FullName)) {
        Write-Log "Update install  [ERROR] Staged v$newVersion failed syntax validation just before install. NOT installing." "ERROR"
        Send-Alert -Title "ThermalGuard update refused" -Body "Staged v$newVersion failed syntax validation. Not installed." -Priority "high"
        return
    }

    # Fresh backup of the file that is live RIGHT NOW, named after the version
    # it contains. This process runs from that very file, so $ScriptVersion is
    # its version. Rollback always restores exactly this copy.
    $rollbackSource = Join-Path $paths.Dir "$($paths.BaseName).backup-v$ScriptVersion.ps1"
    try {
        Copy-Item -Path $paths.LivePath -Destination $rollbackSource -Force -ErrorAction Stop
    } catch {
        Write-Log "Update install  [ERROR] Could not back up the live script to $rollbackSource : $_ . NOT installing." "ERROR"
        Send-Alert -Title "ThermalGuard update failed" -Body "Could not create the rollback backup. Nothing was changed." -Priority "urgent"
        return
    }

    Write-Log "Update install  Installing staged update: $($pending.Name) -> $($paths.LivePath) (rollback copy: $rollbackSource)"

    Set-GuardTaskEnabled -Enabled $false
    Stop-RunningGuardProcesses

    try {
        Copy-Item -Path $pending.FullName -Destination $paths.LivePath -Force -ErrorAction Stop
        Remove-Item -Path $pending.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $sidecar -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Update install  [ERROR] Could not copy staged file into place: $_" "ERROR"
        Send-Alert -Title "ThermalGuard update failed" -Body "Could not install v$newVersion : $_" -Priority "urgent"
        Set-GuardTaskEnabled -Enabled $true
        try { Start-GuardAfterSwap } catch { Write-Log "Update install  [ERROR] Could not restart the guard: $_" "ERROR" }
        return
    }

    $restartTime = Get-Date
    Set-GuardTaskEnabled -Enabled $true
    try {
        Start-GuardAfterSwap
    } catch {
        Write-Log "Update install  [ERROR] Could not start the guard after swap: $_" "ERROR"
    }

    # Healthy = the new process logged the explicit health marker, which the
    # main loop writes on its first poll that resolved a valid temperature.
    # "Software Check complete" is NOT enough: that line is logged on failure too.
    Write-Log "Update install  Waiting up to ${UpdateHealthCheckTimeoutSec}s for v$newVersion to come up healthy..."
    $healthy      = $false
    $deadline     = $restartTime.AddSeconds($UpdateHealthCheckTimeoutSec)
    $markerRegex  = [regex]::Escape($HealthMarkerText)
    # Log timestamps are truncated to whole seconds, so compare against the
    # restart time truncated the same way. A marker line from before the swap
    # cannot land in the same second: the old process is killed at least 2s earlier.
    $notBefore    = [datetime]::ParseExact($restartTime.ToString('yyyy-MM-dd HH:mm:ss'), 'yyyy-MM-dd HH:mm:ss', $null)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (-not (Test-Path $LogFile)) { continue }
        $tail = Get-Content $LogFile -Tail 300 -ErrorAction SilentlyContinue
        $markerLine = $tail | Where-Object { $_ -match $markerRegex } | Select-Object -Last 1
        if ($markerLine -and $markerLine -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') {
            try {
                $lineTime = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
                if ($lineTime -ge $notBefore) { $healthy = $true; break }
            } catch { }
        }
    }

    if ($healthy) {
        Write-Log "Update install  [OK] v$newVersion is up and healthy."
        Send-Alert -Title "ThermalGuard updated" -Body "Successfully installed v$newVersion." -Priority "default"
        return
    }

    Write-Log "Update install  [ERROR] v$newVersion did not become healthy within ${UpdateHealthCheckTimeoutSec}s. Rolling back..." "ERROR"
    Send-Alert -Title "ThermalGuard update failed, rolling back" `
        -Body "v$newVersion did not start correctly. Restoring the previous working version." -Priority "urgent"

    # Remember the failure so the (old, restored) guard does not stage and
    # install the very same version again on its next start.
    try {
        Set-Content -Path (Join-Path $paths.Dir "$($paths.BaseName).failed-v$newVersion.txt") `
            -Value "v$newVersion failed its health check on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') and was rolled back. Delete this file to allow another attempt." `
            -Encoding ASCII -ErrorAction Stop
    } catch { }

    Set-GuardTaskEnabled -Enabled $false
    Stop-RunningGuardProcesses

    if (Test-Path $rollbackSource) {
        try {
            Copy-Item -Path $rollbackSource -Destination $paths.LivePath -Force -ErrorAction Stop
            Write-Log "Update install  Restored $rollbackSource back to $($paths.LivePath)"
        } catch {
            Write-Log "Update install  [FATAL] Rollback copy itself failed: $_" "ERROR"
            Send-Alert -Title "ThermalGuard rollback FAILED" `
                -Body "Manual intervention needed: restore $rollbackSource to $($paths.LivePath) by hand." -Priority "urgent"
        }
    } else {
        Write-Log "Update install  [FATAL] No backup file found at $rollbackSource to roll back to!" "ERROR"
        Send-Alert -Title "ThermalGuard rollback FAILED" `
            -Body "No backup found. Manual intervention needed at $($paths.LivePath)." -Priority "urgent"
    }

    Set-GuardTaskEnabled -Enabled $true
    try {
        Start-GuardAfterSwap
    } catch {
        Write-Log "Update install  [ERROR] Could not restart the guard after rollback: $_" "ERROR"
    }
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

$script:LoggedFallbackUsed = @{}

function Find-SensorValueSingle {
    param($SensorData, [string]$Match, $PreferredSensorIndex = $null, [string]$PreferredUnit = $null, [string]$RequiredUnitPattern = $null)

    # SAFETY GUARD: no real HWiNFO sensor label is 1-2 characters long. If
    # $Match ever ends up that short (observed in production as a single
    # stray 'G' - root cause not fully confirmed, suspected an array/string
    # normalization edge case upstream), a "*G*" partial match would hit
    # essentially any reading containing that letter, including completely
    # unrelated RAM/memory readings, and hand back a value like 10019 that
    # then gets compared against a Crit threshold as if it were a real
    # temperature. Refuse outright rather than risk that.
    if ($Match.Length -le 2) {
        if (-not $script:LoggedSensorMatchWarnings["SHORT:$Match"]) {
            Write-Log "REFUSED implausibly short SensorMatch candidate: '$Match' (length $($Match.Length)) - this would match almost anything" "ERROR"
            $script:LoggedSensorMatchWarnings["SHORT:$Match"] = $true
        }
        return $null
    }

    $exactMatches   = @()
    $partialMatches = @()
    foreach ($reading in $SensorData.readings) {
        $lo = [string]$reading.labelOriginal
        $lu = [string]$reading.labelUser
        if ($lo -eq $Match -or $lu -eq $Match)            { $exactMatches   += $reading; continue }
        if ($lo -like "*$Match*" -or $lu -like "*$Match*") { $partialMatches += $reading }
    }

    # HARD unit filter (used for the dedicated temperature sensors): a reading
    # whose unit is not a temperature is never used as one, no matter how well
    # its label matches. Without this, a partial label match such as
    # "CPU Package" can land on "CPU Package Power" (W) and hand a wattage to a
    # degrees-C comparison. If the filter removes every candidate, the sensor
    # counts as missing (loud, logged once) instead of silently using a wrong one.
    if ($RequiredUnitPattern) {
        $beforeCount    = $exactMatches.Count + $partialMatches.Count
        $exactMatches   = @($exactMatches   | Where-Object { [string]$_.unit -match $RequiredUnitPattern })
        $partialMatches = @($partialMatches | Where-Object { [string]$_.unit -match $RequiredUnitPattern })
        if ($beforeCount -gt 0 -and ($exactMatches.Count + $partialMatches.Count) -eq 0) {
            if (-not $script:LoggedSensorMatchWarnings["UNIT:$Match"]) {
                Write-Log "SensorMatch '$Match' only matched readings whose unit is not a temperature - refusing to use them as a temperature" "ERROR"
                $script:LoggedSensorMatchWarnings["UNIT:$Match"] = $true
            }
        }
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
    # SAFETY-CRITICAL FIX: this feeds the dedicated CPU/GPU Warn/Crit/
    # Stage2/Stage3 shutdown comparisons. A plain [double] cast on a STRING
    # value goes through .NET's Convert.ToDouble internally, which uses the
    # current Windows culture - on de-AT/de-DE systems (where "." is the
    # thousands separator) a value like "100.19" can get its decimal point
    # silently swallowed and read back as 10019. That garbled, hugely
    # inflated number is always >= any sane Crit threshold, which can
    # trigger a completely spurious emergency shutdown on a totally normal
    # temperature. If the value from ConvertFrom-Json is already a native
    # numeric type (the common case), casting it is a no-op and stays safe;
    # only the string case needs the explicit invariant-culture parse.
    $rawValue = $m[0].value
    if ($rawValue -is [double] -or $rawValue -is [int] -or $rawValue -is [long] -or $rawValue -is [decimal]) {
        return [double]$rawValue
    }
    $parsed = $null
    if ([double]::TryParse(
            [string]$rawValue,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Find-SensorValue {
    param($SensorData, $Match, $PreferredSensorIndex = $null, [string]$PreferredUnit = $null, [string]$SensorDisplayName = $null, [string]$RequiredUnitPattern = $null)

    # Explicit type check (not an "is it NOT an array" inference): a genuine
    # [string] goes straight to Find-SensorValueSingle with zero
    # normalization in between. Only real arrays (currently just the CPU
    # entry's fallback chain) go through the candidate loop below. See the
    # self-test block above for why this was split out this way.
    if ($Match -is [string]) {
        return Find-SensorValueSingle -SensorData $SensorData -Match $Match -PreferredSensorIndex $PreferredSensorIndex -PreferredUnit $PreferredUnit -RequiredUnitPattern $RequiredUnitPattern
    }

    $candidates = $Match

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $value = Find-SensorValueSingle -SensorData $SensorData -Match $candidates[$i] -PreferredSensorIndex $PreferredSensorIndex -PreferredUnit $PreferredUnit -RequiredUnitPattern $RequiredUnitPattern
        if ($null -ne $value) {
            if ($i -gt 0) {
                $logKey = "$SensorDisplayName|$($candidates[$i])"
                if (-not $script:LoggedFallbackUsed[$logKey]) {
                    Write-Log "Sensor fallback: '$SensorDisplayName' - primary label '$($candidates[0])' not found, using fallback '$($candidates[$i])'"
                    $script:LoggedFallbackUsed[$logKey] = $true
                }
            }
            return $value
        }
    }
    return $null
}

function Find-GPULoad {
    param($SensorData)
    $loadMatch = $GPUProfiles[$GPUProfile].LoadMatch
    return Find-SensorValue -SensorData $SensorData -Match $loadMatch -PreferredSensorIndex $script:DetectedGPUSensorIndex
}

# === STAGE 2 / STAGE 3 ========================================================

function Invoke-KillProcesses {
    Write-Log "=== STAGE 2: killing processes ===$(if ($DryRun) {' [DRYRUN]'})" "CRIT"
    foreach ($proc in $KillProcesses) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            if ($DryRun) {
                Write-Log "[DRYRUN] would kill: $proc (PID: $($running.Id -join ', '))" "CRIT"
            } else {
                Write-Log "Killing: $proc (PID: $($running.Id -join ', '))"
                Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-Shutdown {
    if ($DryRun) {
        Write-Log "=== STAGE 3: EMERGENCY SHUTDOWN [DRYRUN] ===" "CRIT"
        Write-Log "[DRYRUN] would run: shutdown.exe /s /f /t 0 - NOT executed. Simulation ends here, the script exits." "CRIT"
        Send-Alert -Title "EMERGENCY SHUTDOWN" -Body "Dry run: the system would be shutting down now. Nothing was shut down." -Priority "urgent"
        return
    }
    Write-Log "=== STAGE 3: EMERGENCY SHUTDOWN ===" "CRIT"
    # Shutdown FIRST, alert second. The alert (toast + ntfy) is network and UI
    # work that can hang for many seconds (DNS, blocked proxy); it used to run
    # before the shutdown and could delay the emergency stop by that long. The
    # short countdown gives the alert a bounded window to go out.
    & shutdown.exe /s /f /t $EmergencyShutdownDelaySec
    if ($LASTEXITCODE -ne 0) {
        Write-Log "shutdown.exe returned exit code $LASTEXITCODE - the system may NOT be shutting down" "ERROR"
    }
    Send-Alert -Title "EMERGENCY SHUTDOWN" -Body "System is shutting down in ${EmergencyShutdownDelaySec}s." -Priority "urgent"
}

# === DATA-LOSS FAIL-SAFE =====================================================
# Blind = no valid reading from the primary CPU/GPU temperature sensors. Until
# this existed, "endpoint down" or "sensor missing" only produced alerts while
# the Stage 2/3 timers (which need a reading to run) froze. Now being blind for
# long enough is treated like an overheat: Stage 2 first, then shutdown.
# Returns $true when it has just triggered the shutdown (caller must stop).

$script:BlindSince      = $null
$script:BlindStage2Done = $false

function Invoke-DataLossFailsafe {
    param([bool]$IsBlind)

    if (-not $EnableDataLossFailsafe) { return $false }

    if (-not $IsBlind) {
        if ($null -ne $script:BlindSince) {
            $secs = [int]((Get-Date) - $script:BlindSince).TotalSeconds
            Write-Log "Data-loss fail-safe: valid temperature data is back after ${secs}s, counter reset"
        }
        $script:BlindSince      = $null
        $script:BlindStage2Done = $false
        return $false
    }

    if ($null -eq $script:BlindSince) {
        $script:BlindSince = Get-Date
        Write-Log "Data-loss fail-safe: no valid CPU/GPU temperature, counting (Stage 2 after ${DataLossStage2Sec}s, shutdown after ${DataLossShutdownSec}s blind)" "WARN"
        return $false
    }

    $blindSec = [int]((Get-Date) - $script:BlindSince).TotalSeconds

    if ($blindSec -ge $DataLossStage2Sec -and -not $script:BlindStage2Done) {
        $script:BlindStage2Done = $true
        Write-Log "Data-loss fail-safe: blind for ${blindSec}s, STAGE 2" "CRIT"
        Send-Alert -Title "Fail-safe Stage 2: no temperature data" `
            -Body "Blind for ${blindSec}s. Killing processes now, shutdown after ${DataLossShutdownSec}s blind if data does not come back." `
            -Priority "urgent"
        Invoke-KillProcesses
    }

    if ($blindSec -ge $DataLossShutdownSec) {
        Write-Log "Data-loss fail-safe: blind for ${blindSec}s, SHUTDOWN" "CRIT"
        Invoke-Shutdown
        return $true
    }
    return $false
}

# === STAGE 2 / 3 ESCALATION FOR A RUNNING CRITICAL TIMER ======================
# Shared by the per-sensor evaluation and by the "no data at all" path of the
# main loop, so a critical sensor escalates the same way whether its readings
# are still arriving or the whole endpoint has gone dark mid-escalation.
# Returns $true when the emergency shutdown has just been triggered (the caller
# must stop); use "-contains $true" on the result.

$script:GlobalStage2Executed = $false

function Invoke-CriticalEscalation {
    param(
        [string]$Name,
        [string]$ValueText,
        [hashtable]$TriggerTimestamps,
        [hashtable]$Stage2Executed
    )

    $elapsed = [int](((Get-Date) - $TriggerTimestamps[$Name]).TotalSeconds)

    if ($elapsed -ge $Stage2Delay -and -not $Stage2Executed[$Name]) {
        Write-Log "${Name}: ${elapsed}s critical, stage 2" "CRIT"
        Send-Alert -Title "Stage 2: processes killed" -Body "$Name at $ValueText for ${elapsed}s" -Priority "urgent"
        if (-not $script:GlobalStage2Executed) {
            Invoke-KillProcesses
            $script:GlobalStage2Executed = $true
        }
        $Stage2Executed[$Name] = $true
    }

    if ($elapsed -ge $Stage3Delay) {
        Write-Log "${Name}: ${elapsed}s critical, stage 3: SHUTDOWN" "CRIT"
        Invoke-Shutdown
        return $true
    }
    return $false
}

# === WATCHDOG =================================================================
# Report finding #8: the watchdog now tracks ENDPOINT HEALTH (does the
# server actually return readable sensor data), not just whether the
# process names exist. A process can be alive and hung, or alive with
# Shared Memory disabled, while still showing up in Get-Process.

function Test-EndpointHealthy {
    # Report finding #23: distinguish WHY the endpoint is unhealthy instead of
    # collapsing every failure into one generic bool. RemoteHWInfo is started
    # with "-hwinfo=1 -gpuz=0 -afterburner=0", so its own log always shows
    # OpenFileMappingA("GPUZShMem") and OpenFileMappingA("MAHMSharedMemory")
    # returning a NULL handle -- that is expected and NOT a problem, since
    # those two sources are intentionally disabled. Only a NULL handle for
    # "Global\HWiNFO_SENS_SM2" (i.e. $r.hwinfo has no readings even though the
    # HTTP endpoint answered) means HWiNFO's own Shared Memory Support is off.
    # That distinction previously only existed in a human's head after reading
    # RemoteHWInfo's raw log; now the watchdog says it directly.
    try {
        $r = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Healthy = $false
            Reason  = "Endpoint not reachable ($HWiNFO_URL) - RemoteHWInfo may still be starting or has crashed."
        }
    }

    if ($null -ne $r.hwinfo -and $null -ne $r.hwinfo.readings -and $r.hwinfo.readings.Count -gt 0) {
        return [PSCustomObject]@{
            Healthy = $true
            Reason  = "$($r.hwinfo.readings.Count) readings"
        }
    }

    return [PSCustomObject]@{
        Healthy = $false
        Reason  = "Endpoint reachable but no HWiNFO readings (empty/near-empty JSON). This points to HWiNFO's own 'Shared Memory Support' setting being disabled, NOT to GPU-Z/Afterburner (those are intentionally off via -gpuz=0 -afterburner=0). Fix: HWiNFO64 -> Settings -> enable 'Shared Memory Support', then restart HWiNFO64."
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

    Invoke-UpdateCheck

    $hwProc = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
    $rhProc = Get-Process RemoteHWInfo -ErrorAction SilentlyContinue
    $endpointDiag = Test-EndpointHealthy
    $endpointOk = $endpointDiag.Healthy

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
        if ($runtimeMin -ge $HWiNFOMaxRuntimeMin -and $script:AnyStageCriticalActive -and -not $script:Reset12hDeferredLogged) {
            # The reset blocks this loop for ~30s. Never do that while a
            # Stage 2/3 timer is running; try again at the next watchdog cycle
            # (the real session limit is 720 min, the default trigger 690).
            Write-Log "WATCHDOG: 12h reset deferred, a critical timer or data-loss counter is active" "WARN"
            $script:Reset12hDeferredLogged = $true
        }
        if ($runtimeMin -ge $HWiNFOMaxRuntimeMin -and -not $script:AnyStageCriticalActive) {
            $script:Reset12hDeferredLogged = $false
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
        Write-Log "  Reason: $($endpointDiag.Reason)" "WARN"
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
                    # Short check only: this runs inside the polling loop and must not block it for long.
                    Start-Sleep -Milliseconds 1500
                    $proc.Refresh()
                    if (-not $proc.HasExited) {
                        Write-Log "WATCHDOG: fipha restarted (PID $($proc.Id))"
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
    Write-Log "All-temps report: $(if ($EnableAllTempsReport) {"ON (CPU/GPU >$AllTempsReportThreshold_CpuGpu C, Board/RAM >$AllTempsReportThreshold_Board C)"} else {'OFF'})"
    Write-Log "fipha:           $(if ($EnableFipha) {'ON'} else {'OFF'})"
    Write-Log "Sensors:         $($Sensors.Count) configured"
    Write-Log "Polling:         every ${PollInterval}s"
    Write-Log "Stage 2 after ${Stage2Delay}s / Stage 3 after ${Stage3Delay}s"
    Write-Log "Watchdog:        $(if ($EnableWatchdog) {'ON'} else {'OFF'})"
    Write-Log "12h Reset:       $(if ($EnableHWiNFO12hReset) {"ON (after $HWiNFOMaxRuntimeMin min)"} else {'OFF'})"
    Write-Log "Data-loss fail-safe: $(if ($EnableDataLossFailsafe) {"ON (Stage 2 after ${DataLossStage2Sec}s, shutdown after ${DataLossShutdownSec}s without valid CPU/GPU temperature)"} else {'OFF'})"
    if ($DryRun) {
        Write-Log "*** DRY RUN: Stage 2/3 are only logged, nothing is killed or shut down. Watchdog and update check are off. ***" "WARN"
    }
    if (-not [double]::IsNaN($SimulateTemp)) {
        Write-Log "*** SIMULATED CPU temperature: $SimulateTemp C (overrides the real 'CPU Tctl/Tdie' reading) ***" "WARN"
    }

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

    Invoke-UpdateCheck

    $triggerTimestamps      = @{}
    $stage2Executed         = @{}
    $warnSent               = @{}
    $missingSensorCounts    = @{}
    $missingSensorLastAlert = @{}
    $endpointDown           = $false
    $lastEndpointAlert      = $null
    $script:GlobalStage2Executed = $false
    $lastWatchdogRun        = $null
    $unhealthyCycleCount    = 0
    $selfTestPrinted        = $false
    $healthMarkerLogged     = $false
    $fanSeenSpinning        = @{}
    $presumedLogged         = @{}
    $lastLoopTick           = $null

    # Primary temperature sensors: if none of these has a valid reading the
    # guard is blind (see Invoke-DataLossFailsafe).
    $primaryTemps = @()
    if ($EnableCPU) { $primaryTemps += "CPU Tctl/Tdie" }
    if ($EnableGPU) { $primaryTemps += "GPU Temperature" }

    while ($true) {
        # Wall-clock timers are meaningless across a suspend/resume or a frozen
        # process: start fresh instead of counting time nobody measured.
        $loopTick = Get-Date
        if ($null -ne $lastLoopTick -and (($loopTick - $lastLoopTick).TotalSeconds -gt $LoopGapResetSec)) {
            Write-Log "Main loop gap of $([int](($loopTick - $lastLoopTick).TotalSeconds))s (suspend/resume or frozen process): Stage 2/3 timers and the data-loss counter are reset" "WARN"
            $triggerTimestamps.Clear()
            $stage2Executed.Clear()
            $presumedLogged.Clear()
            $script:GlobalStage2Executed = $false
            $script:BlindSince      = $null
            $script:BlindStage2Done = $false
        }
        $lastLoopTick = $loopTick

        # Nothing in the info/maintenance subsystems may end the protection
        # loop: each one is contained and logged (rate-limited), the sensor
        # evaluation below still runs.
        if ($EnableWatchdog) {
            try {
                Invoke-Watchdog -LastWatchdogRun ([ref]$lastWatchdogRun) -UnhealthyCycleCount ([ref]$unhealthyCycleCount)
            } catch { Write-GuardError -Name "Watchdog" -ErrorRecord $_ }
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
            # Blind: keep updates away and let the data-loss fail-safe count.
            $script:AnyStageCriticalActive = $true
            if ((Invoke-DataLossFailsafe -IsBlind ($primaryTemps.Count -gt 0)) -contains $true) { return }

            # A critical timer that was already running when the data went dark
            # (e.g. HWiNFO crashed because the PC is hot) must not freeze: the
            # sensor is presumed to still be critical and keeps escalating
            # instead of waiting for the much slower data-loss fail-safe.
            foreach ($critName in @($triggerTimestamps.Keys)) {
                if (-not $presumedLogged[$critName]) {
                    Write-Log "${critName}: no sensor data at all while its critical timer is running - presuming it is still critical ($([int](((Get-Date) - $triggerTimestamps[$critName]).TotalSeconds))s so far)" "CRIT"
                    $presumedLogged[$critName] = $true
                }
                if ((Invoke-CriticalEscalation -Name $critName -ValueText "no data (presumed critical)" -TriggerTimestamps $triggerTimestamps -Stage2Executed $stage2Executed) -contains $true) { return }
            }
            Start-Sleep -Seconds $PollInterval
            continue
        }

        if ($endpointDown) {
            Write-Log "Endpoint reachable again"
            $endpointDown      = $false
            $lastEndpointAlert = $null
        }

        try { Resolve-GPUSensorIndex -SensorData $sensorData } catch { Write-GuardError -Name "GPU sensor index" -ErrorRecord $_ }
        try { Invoke-AllTempsReportCheck -SensorData $sensorData } catch { Write-GuardError -Name "All-temps report" -ErrorRecord $_ }
        try { Invoke-PerfLimitCheck -SensorData $sensorData } catch { Write-GuardError -Name "Performance-limit check" -ErrorRecord $_ }
        try { Invoke-InfoAlertDigestFlush } catch { Write-GuardError -Name "Info-alert digest" -ErrorRecord $_ }

        # Report finding #10: explicit self-test on the first successful
        # poll so an operator can verify exactly which sensor each
        # configured entry actually resolved to.
        if (-not $selfTestPrinted) {
            # Marked done up front: a self-test that throws must not repeat on every poll.
            $selfTestPrinted = $true
            try {
                Write-Log "=== Sensor self-test (first successful poll) ==="
                foreach ($sensor in $Sensors) {
                    if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
                    if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }

                    # Explicit type check, not an "is it NOT an array" inference:
                    # a genuine [string] always takes the exact single-candidate
                    # path that worked correctly pre-fallback-chains (v1.46).
                    # Only real arrays (currently just the CPU entry) go through
                    # the multi-candidate loop below. This was rewritten after a
                    # production incident where GPU sensors (plain strings) got
                    # corrupted into a single stray character ('G') somewhere in
                    # the array-normalization path - the exact mechanism was
                    # never fully confirmed even after extensive review, so
                    # rather than patch a suspect line, the string case now
                    # bypasses that code path entirely.
                    if ($sensor.SensorMatch -is [string]) {
                        $singleMatch = $sensor.SensorMatch
                        $candidates = $sensorData.readings | Where-Object {
                            $_.labelOriginal -eq $singleMatch -or $_.labelUser -eq $singleMatch -or
                            $_.labelOriginal -like "*$singleMatch*" -or $_.labelUser -like "*$singleMatch*"
                        }
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
                            Write-Log "  $($sensor.Name) -> NO MATCH for '$singleMatch'$(if ($sensor.Optional) {' (optional sensor)'})" $(if ($sensor.Optional) { "INFO" } else { "WARN" })
                        }
                        continue
                    }

                    $matchCandidates = $sensor.SensorMatch
                    $reading = $null
                    $matchedCandidate = $null
                    foreach ($candidate in $matchCandidates) {
                        $candidates = $sensorData.readings | Where-Object {
                            $_.labelOriginal -eq $candidate -or $_.labelUser -eq $candidate -or
                            $_.labelOriginal -like "*$candidate*" -or $_.labelUser -like "*$candidate*"
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
                        if ($reading) { $matchedCandidate = $candidate; break }
                    }
                    if ($reading) {
                        $fallbackNote = if ($matchedCandidate -ne $matchCandidates[0]) { " (fallback: primary '$($matchCandidates[0])' not found)" } else { "" }
                        Write-Log "  $($sensor.Name) -> labelOriginal='$($reading.labelOriginal)' sensorIndex=$($reading.sensorIndex) readingId=$($reading.readingId) unit=$($reading.unit) value=$($reading.value)$fallbackNote"
                    } else {
                        $matchDisplay = $matchCandidates -join "' / '"
                        Write-Log "  $($sensor.Name) -> NO MATCH for '$matchDisplay'$(if ($sensor.Optional) {' (optional sensor)'})" $(if ($sensor.Optional) { "INFO" } else { "WARN" })
                    }
                }
                # The lines above only show which readings match by label. This shows
                # whether the REAL lookup (incl. index/unit filters) resolves them.
                foreach ($sensor in $Sensors) {
                    if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
                    if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }
                    $stUnitHint    = if ($sensor.Type -eq "fan")  { "RPM" } else { $null }
                    $stUnitPattern = if ($sensor.Type -eq "temp") { $DedicatedTempUnitPattern } else { $null }
                    $stValue = Find-SensorValue -SensorData $sensorData -Match $sensor.SensorMatch -PreferredSensorIndex $sensor.PreferredSensorIndex -PreferredUnit $stUnitHint -SensorDisplayName $sensor.Name -RequiredUnitPattern $stUnitPattern
                    if ($null -eq $stValue) {
                        Write-Log "  $($sensor.Name) -> NOT resolved by the live lookup$(if ($sensor.Optional) {' (optional sensor)'})" $(if ($sensor.Optional) { "INFO" } else { "WARN" })
                    }
                }
                Write-Log "=== End self-test ==="
            } catch { Write-GuardError -Name "Sensor self-test" -ErrorRecord $_ }
        }

        $gpuLoad = $null
        if ($EnableGPU) {
            try { $gpuLoad = Find-GPULoad -SensorData $sensorData } catch { Write-GuardError -Name "GPU load lookup" -ErrorRecord $_ }
        }

        # GPU temperature for the fan evaluation: a stopped fan only counts once
        # the GPU is warm (see $GPU_FanStopMinTempC). Same lookup, unit filter and
        # plausibility bounds as the dedicated "GPU Temperature" sensor.
        $gpuTemp = $null
        if ($EnableGPU) {
            try {
                $gpuTemp = Find-SensorValue -SensorData $sensorData -Match $GPUProfiles[$GPUProfile].TempMatch -PreferredSensorIndex $script:DetectedGPUSensorIndex -SensorDisplayName "GPU Temperature" -RequiredUnitPattern $DedicatedTempUnitPattern
            } catch { Write-GuardError -Name "GPU temperature lookup" -ErrorRecord $_ }
            if ($null -ne $gpuTemp -and ($gpuTemp -lt $TempSanityMinC -or $gpuTemp -gt $TempSanityMaxC)) { $gpuTemp = $null }
        }
        $gpuWarm = ($null -ne $gpuTemp -and $gpuTemp -ge $GPU_FanStopMinTempC)

        $tempOk = @{}

        foreach ($sensor in $Sensors) {
            if ($sensor.Group -eq "CPU" -and -not $EnableCPU) { continue }
            if ($sensor.Group -eq "GPU" -and -not $EnableGPU) { continue }

            $sName = $sensor.Name

            # One sensor's evaluation throwing must neither end the monitoring
            # loop nor stop the other sensors from being evaluated. A sensor that
            # cannot be evaluated is not a valid reading: it is removed from
            # $tempOk, so for the primary CPU/GPU temperatures the data-loss
            # fail-safe counts it as blind.
            try {
                $unitHint    = if ($sensor.Type -eq "fan")  { "RPM" } else { $null }
                $unitPattern = if ($sensor.Type -eq "temp") { $DedicatedTempUnitPattern } else { $null }
                $value = Find-SensorValue -SensorData $sensorData -Match $sensor.SensorMatch -PreferredSensorIndex $sensor.PreferredSensorIndex -PreferredUnit $unitHint -SensorDisplayName $sName -RequiredUnitPattern $unitPattern

                # -SimulateTemp: pretend the CPU temperature (implies -DryRun).
                if (-not [double]::IsNaN($SimulateTemp) -and $sName -eq "CPU Tctl/Tdie") { $value = $SimulateTemp }

                if ($null -eq $value) {
                    # Optional sensors (e.g. GPU Fan 2) may legitimately not exist.
                    if (-not $sensor.Optional) {
                        $missingSensorCounts[$sName] = [int]$missingSensorCounts[$sName] + 1
                        if ($missingSensorCounts[$sName] -ge $MissingSensorAlertAfterPolls) {
                            $lastMissingAlert = $missingSensorLastAlert[$sName]
                            if (($null -eq $lastMissingAlert) -or (((Get-Date) - $lastMissingAlert).TotalMinutes -ge $MissingSensorAlertIntervalMinutes)) {
                                $matchDisplay = if ($sensor.SensorMatch -is [array]) { $sensor.SensorMatch -join "' / '" } else { $sensor.SensorMatch }
                                Write-Log "Sensor missing: $sName ('$matchDisplay')" "ERROR"
                                Send-Alert -Title "Sensor missing" -Body "$sName not found" -Priority "urgent"
                                $missingSensorLastAlert[$sName] = Get-Date
                            }
                        }
                    }
                }
                elseif ($sensor.Type -eq "temp" -and ($value -lt $TempSanityMinC -or $value -gt $TempSanityMaxC)) {
                    # SAFETY NET: refuse to treat an implausible value as a real
                    # temperature, regardless of how it got here. A correctly
                    # functioning sensor never reports below -20 C or above 150 C;
                    # if this ever fires, something upstream misidentified a reading
                    # (confirmed once in production: a RAM/memory value in MB got
                    # compared against a Crit threshold as if it were degrees C,
                    # triggering a false emergency shutdown at ~45 C real GPU temp).
                    if (-not $script:LoggedImplausibleTemp[$sName]) {
                        Write-Log "${sName}: IMPLAUSIBLE value $value degrees (outside $TempSanityMinC..$TempSanityMaxC C) - treating as a bad reading, NOT evaluating Warn/Crit this poll" "ERROR"
                        Send-Alert -Title "Sensor data implausible: $sName" -Body "Got $value degrees, which is outside any real range. Ignoring this reading rather than risk a false shutdown." -Priority "urgent"
                        $script:LoggedImplausibleTemp[$sName] = $true
                    }
                    $value = $null
                }
                else {
                    if ($missingSensorCounts.ContainsKey($sName)) {
                        if ($missingSensorCounts[$sName] -ge $MissingSensorAlertAfterPolls) {
                            Write-Log "$sName found again: $value"
                        }
                        $missingSensorCounts.Remove($sName)
                        $missingSensorLastAlert.Remove($sName)
                    }
                    $script:LoggedImplausibleTemp.Remove($sName)
                    if ($sensor.Type -eq "temp") { $tempOk[$sName] = $true }
                }

                # No usable reading (missing or implausible). A sensor with no
                # running critical timer is simply skipped this poll. One that is
                # ALREADY inside its Stage 2/3 timer is presumed to still be
                # critical: going dark mid-escalation must neither freeze the
                # timer (the sensor would then escape Stage 3 for as long as it
                # stays unreadable) nor leave a stale timer that fires instantly
                # the moment the sensor comes back.
                $presumedCritical = $false
                if ($null -eq $value) {
                    if ($triggerTimestamps[$sName]) { $presumedCritical = $true } else { continue }
                }

                $isCritical = $false

                if ($presumedCritical) {
                    $isCritical = $true
                    if (-not $presumedLogged[$sName]) {
                        Write-Log "${sName}: no valid reading while its critical timer is running - presuming it is still critical ($([int](((Get-Date) - $triggerTimestamps[$sName]).TotalSeconds))s so far)" "CRIT"
                        $presumedLogged[$sName] = $true
                    }
                }
                else {
                    $presumedLogged.Remove($sName)

                    # Armed-after-spinning for optional fans: a 0 RPM reading that has
                    # never been above 0 in this run is a phantom sensor, not a dead fan.
                    if ($sensor.Optional -and $sensor.Type -eq "fan") {
                        if ($value -gt 0) { $fanSeenSpinning[$sName] = $true }
                        if (-not $fanSeenSpinning[$sName]) { continue }
                    }

                    if ($sensor.Type -eq "temp") {
                        if ($value -ge $sensor.WarnThreshold -and -not $warnSent[$sName]) {
                            Write-Log "${sName}: WARNING ${value} degrees (threshold: $($sensor.WarnThreshold))" "WARN"
                            # Warn is informational only - Crit detection below reads
                            # $value directly, not this flag, so queuing this instead
                            # of sending immediately does not delay the Stage2/Stage3
                            # kill/shutdown escalation in any way.
                            Queue-InfoAlert -Line "$sName warning: ${value} degrees reached (threshold: $($sensor.WarnThreshold))"
                            $warnSent[$sName] = $true
                        }
                        $isCritical = ($value -ge $sensor.CritThreshold)
                        # Inside the hysteresis band a running timer keeps running.
                        if (-not $isCritical -and $triggerTimestamps[$sName] -and $value -ge ($sensor.CritThreshold - $CritResetHysteresisC)) {
                            $isCritical = $true
                        }
                    }
                    elseif ($sensor.Type -eq "fan") {
                        # Needs load AND a warm GPU: cards with a zero-RPM mode stop
                        # their fans on purpose when cool, even at 50% load.
                        if ($null -ne $gpuLoad -and $gpuLoad -ge $GPULoadThreshold -and $gpuWarm) {
                            if ($value -le $sensor.WarnThreshold -and $value -gt $sensor.CritThreshold -and -not $warnSent[$sName]) {
                                Write-Log "${sName}: WARNING ${value} RPM at ${gpuLoad}% load" "WARN"
                                # Same reasoning as the temp warn above: purely
                                # informational, Crit detection is independent of it.
                                Queue-InfoAlert -Line "$sName warning: ${value} RPM at ${gpuLoad}% load"
                                $warnSent[$sName] = $true
                            }
                            $isCritical = ($value -le $sensor.CritThreshold)
                        }
                    }
                }

                $valueText = if ($presumedCritical) { "no reading (presumed critical)" } else { "$value" }

                if ($isCritical) {
                    if (-not $triggerTimestamps[$sName]) {
                        $triggerTimestamps[$sName] = Get-Date
                        Write-Log "${sName}: CRITICAL value=$value, timer started" "CRIT"
                        Send-Alert -Title "$sName CRITICAL" -Body "Value: $value, shutdown in ${Stage3Delay}s if sustained" -Priority "urgent"
                        $warnSent[$sName] = $true
                    }

                    if ((Invoke-CriticalEscalation -Name $sName -ValueText $valueText -TriggerTimestamps $triggerTimestamps -Stage2Executed $stage2Executed) -contains $true) { return }
                }
                else {
                    if ($triggerTimestamps[$sName]) {
                        Write-Log "${sName}: value normalized ($value), timer reset"
                        $triggerTimestamps.Remove($sName)
                        $stage2Executed.Remove($sName)
                        if ($triggerTimestamps.Count -eq 0) { $script:GlobalStage2Executed = $false }
                    }
                    if ($sensor.Type -eq "temp" -and $value -lt ($sensor.WarnThreshold * 0.95)) {
                        $warnSent.Remove($sName)
                    }
                    elseif ($sensor.Type -eq "fan") {
                        if (($null -eq $gpuLoad) -or ($gpuLoad -lt $GPULoadThreshold) -or (-not $gpuWarm) -or ($value -ge ($sensor.WarnThreshold + 50))) {
                            $warnSent.Remove($sName)
                        }
                    }
                }
            } catch {
                Write-GuardError -Name "Sensor $sName" -ErrorRecord $_
                $tempOk.Remove($sName)
            }
        }

        # Exposed for Invoke-UpdateCheck / Invoke-StageUpdate / Install-ThermalGuardUpdate:
        # never stage or install an update while a sensor is actively mid-way
        # through the Stage 2/3 timer. Overheat handling always outranks
        # updating the script that is doing the handling.
        # Data-loss fail-safe: blind = a primary CPU/GPU temperature has no valid reading.
        $isBlind = (@($primaryTemps | Where-Object { -not $tempOk[$_] }).Count -gt 0)

        # Health marker for the update installer: the first poll in which ALL
        # primary temperature sensors (CPU and GPU, as far as enabled) have a
        # valid reading, i.e. the guard is not blind. One resolved sensor is not
        # enough: a version that breaks only the CPU lookup must not count as healthy.
        if (-not $healthMarkerLogged -and -not $isBlind) {
            Write-Log "=== $HealthMarkerText ($($tempOk.Count) temperature sensor(s) resolved) ==="
            $healthMarkerLogged = $true
        }

        if ((Invoke-DataLossFailsafe -IsBlind $isBlind) -contains $true) { return }

        $script:AnyStageCriticalActive = (($triggerTimestamps.Count -gt 0) -or ($null -ne $script:BlindSince))

        Start-Sleep -Seconds $PollInterval
    }
}

# === START ====================================================================
if ($InstallPendingUpdate) {
    # Installer-only mode: never runs the thermal monitoring loop. Used by
    # Approve-ThermalGuardUpdate.ps1 and internally when $EnableAutoInstall
    # spawns this same script as a detached child process to perform the
    # stop/swap/restart/health-check/rollback sequence.
    Write-Log "=========================================="
    Write-Log "HWiNFO Thermal Guard v$ScriptVersion - running in -InstallPendingUpdate mode"
    Write-Log "=========================================="
    try {
        Install-ThermalGuardUpdate
    } catch {
        Write-Log "Update install  [FATAL] Installer itself crashed: $_" "ERROR"
    } finally {
        # Whatever happened above (success, early return, exception between the
        # disable and the enable): never leave the guard's scheduled task
        # disabled by us. A disabled task means no protection and no self-heal.
        if ($script:GuardTaskDisabledByInstaller) {
            Write-Log "Update install  Re-enabling the scheduled task that this installer disabled" "WARN"
            Set-GuardTaskEnabled -Enabled $true
        }
    }
    exit 0
}

# Single instance: two guards would restart each other's HWiNFO/RemoteHWInfo and
# double every alert. Only the real monitoring mode takes part; -DryRun /
# -SimulateTemp (which never touch anything) and the installer are exempt.
function Enter-SingleInstance {
    $created = $false
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, $InstanceMutexName, [ref]$created)
    } catch {
        $inner = $_.Exception
        if ($inner -isnot [System.UnauthorizedAccessException] -and $inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.UnauthorizedAccessException]) {
            # The mutex exists but belongs to an elevated guard this process may not open.
            return $false
        }
        Write-Log "Single-instance check failed ($($_.Exception.Message)) - continuing without it" "WARN"
        return $true
    }
    if ($created) { return $true }
    # It exists: held by a live guard, or abandoned by a dead one whose handle
    # another process kept alive. Taking it over succeeds only in the second case.
    try {
        if ($script:InstanceMutex.WaitOne(0)) { return $true }
    } catch [System.Threading.AbandonedMutexException] {
        return $true
    }
    return $false
}

if (-not $DryRun) {
    if (-not (Enter-SingleInstance)) {
        Write-Log "Another ThermalGuard instance is already running (mutex '$InstanceMutexName'). This instance exits." "WARN"
        exit 0
    }
}

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
} finally {
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        try { $script:InstanceMutex.Dispose() } catch { }
    }
}
