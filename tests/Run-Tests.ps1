#requires -Version 5.1
# ============================================================================
# Run-Tests.ps1 - behavior tests for HWiNFO-ThermalGuard.ps1
#
# The safety logic (Stage 2/3, data-loss fail-safe, sensor lookup) used to be
# checked only by hand. This runs the REAL script as a child process against a
# mock sensor endpoint (tests/MockEndpoint.ps1, data from
# tests/fixtures/sensors.json) and asserts on its log:
#
#   pwsh -File tests\Run-Tests.ps1                       # all scenarios
#   pwsh -File tests\Run-Tests.ps1 -Only 'fan-*','perf*' # a selection (wildcards)
#   pwsh -File tests\Run-Tests.ps1 -ScriptPath C:\old\HWiNFO-ThermalGuard.ps1
#       (run the same tests against another version, e.g. to see a test FAIL on
#        the code it was written to catch)
#
# Nothing here touches the real installation. The script under test is copied
# to a temp folder and patched there: other endpoint port, other log folder, no
# software check / firewall / registry access, short stage delays (6 s / 14 s),
# toasts and the kill list stubbed, shutdown.exe replaced by a function that
# only writes to the log. Takes about 5 minutes. Exit code = number of failures.
#
# This file is pure ASCII on purpose, like the scripts it tests.
# ============================================================================
param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "HWiNFO-ThermalGuard.ps1"),
    [string[]]$Only = @(),
    [int]$Port = 60999,
    [switch]$KeepFiles,
    [switch]$List
)

$ErrorActionPreference = "Stop"
# "pwsh -File ... -Only a,b" delivers one string "a,b" - split it ourselves.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Engine  = (Get-Process -Id $PID).Path
$Root    = Join-Path ([System.IO.Path]::GetTempPath()) "tg-tests-$PID"
$LogDir  = Join-Path $Root "log"
$LogFile = Join-Path $LogDir "thermalguard.log"
$ScFile  = Join-Path $Root "scenario.json"
$Copy    = Join-Path $Root "tg.ps1"
$Fixture = Join-Path $PSScriptRoot "fixtures\sensors.json"
$Mock    = Join-Path $PSScriptRoot "MockEndpoint.ps1"
$TaskLog = Join-Path $Root "task.log"
$MutexName = "Global\TGTEST-" + [guid]::NewGuid().ToString("N")

# --- build the patched test copy ------------------------------------------------
function New-TestCopy {
    $script:CopyText = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
    function Sub([string]$Old, [string]$New, [switch]$Optional) {
        if (-not $script:CopyText.Contains($Old)) {
            if ($Optional) { return }
            throw "test harness: pattern not found in the script under test (update tests/Run-Tests.ps1): $Old"
        }
        $idx = $script:CopyText.IndexOf($Old)
        $script:CopyText = $script:CopyText.Substring(0, $idx) + $New + $script:CopyText.Substring($idx + $Old.Length)
    }
    Sub '$HWiNFO_URL = "http://localhost:60000/json.json"' ('$HWiNFO_URL = "http://127.0.0.1:' + $Port + '/json.json"')
    Sub '$LogDir       = "$env:USERPROFILE\HWiNFO-ThermalGuard"' ('$LogDir       = "' + $LogDir + '"')
    Sub '$crashLog = Join-Path $env:USERPROFILE "HWiNFO-ThermalGuard"' ('$crashLog = "' + $LogDir + '"')
    Sub '$ready = Test-Requirements' '$ready = $true'
    Sub 'HKCU:\SOFTWARE\HWiNFO64\Settings' 'HKCU:\SOFTWARE\TGTEST_DOES_NOT_EXIST\Settings'
    Sub '$GPUProfile = "AUTO"' '$GPUProfile = "NVIDIA"'
    Sub '$InstanceMutexName = "Global\HWiNFO-ThermalGuard-Instance"' ('$InstanceMutexName = "' + $MutexName + '"') -Optional

    $inject = @'

# ---- test harness overrides (added by tests/Run-Tests.ps1) ----
$Stage2Delay    = 6
$Stage3Delay    = 14
$PollInterval   = 1
$EnableWatchdog = $false
if ($env:TG_GAP) { $LoopGapResetSec = [int]$env:TG_GAP }
if ($env:TG_POLL) { $PollInterval = [int]$env:TG_POLL }
if ($env:TG_FS_STAGE2)   { $DataLossStage2Sec   = [int]$env:TG_FS_STAGE2 }
if ($env:TG_FS_SHUTDOWN) { $DataLossShutdownSec = [int]$env:TG_FS_SHUTDOWN }
$script:DetectedGPUName = "NVIDIA GeForce RTX 5070 Ti"
function Send-Toast { param([string]$Title, [string]$Body) Write-Log "[TEST toast] $Title | $Body" }
if (-not $DryRun) {
    function Invoke-KillProcesses { Write-Log "[TEST] kill stage 2 (stubbed)" "CRIT" }
}
function shutdown.exe { Write-Log "[TEST] shutdown.exe $($args -join ' ')" "CRIT"; $global:LASTEXITCODE = 0 }
if ($env:TG_FAULT -match 'digest') { function Invoke-InfoAlertDigestFlush { throw "injected digest fault" } }
if ($env:TG_FAULT -match 'sensor') {
    $script:OrigFindSensorValue = ${function:Find-SensorValue}
    function Find-SensorValue {
        param($SensorData, $Match, $PreferredSensorIndex = $null, [string]$PreferredUnit = $null, [string]$SensorDisplayName = $null, [string]$RequiredUnitPattern = $null)
        if ($SensorDisplayName -eq 'GPU Memory Junction') { throw "injected sensor fault" }
        & $script:OrigFindSensorValue -SensorData $SensorData -Match $Match -PreferredSensorIndex $PreferredSensorIndex -PreferredUnit $PreferredUnit -SensorDisplayName $SensorDisplayName -RequiredUnitPattern $RequiredUnitPattern
    }
}
if ($env:TG_FAKETASK) {
    function Get-ScheduledTask     { [CmdletBinding()] param([string]$TaskName) [pscustomobject]@{ TaskName = $TaskName } }
    function Enable-ScheduledTask  { [CmdletBinding()] param([string]$TaskName) Add-Content -Path $env:TG_TASKLOG -Value "ENABLE" }
    function Disable-ScheduledTask { [CmdletBinding()] param([string]$TaskName) Add-Content -Path $env:TG_TASKLOG -Value "DISABLE" }
    function Stop-ScheduledTask    { [CmdletBinding()] param([string]$TaskName) Add-Content -Path $env:TG_TASKLOG -Value "STOP" }
    function Start-ScheduledTask   { [CmdletBinding()] param([string]$TaskName) Add-Content -Path $env:TG_TASKLOG -Value "START" }
    if ($env:TG_FAULT -match 'stopproc') { function Stop-RunningGuardProcesses { throw "injected stop fault" } }
    else                                  { function Stop-RunningGuardProcesses { Write-Log "[TEST] stop guard processes (stubbed)" } }
}

'@
    $marker = '# === START ===================================================================='
    Sub $marker ($inject + $marker)
    [System.IO.File]::WriteAllText($Copy, $script:CopyText, (New-Object System.Text.UTF8Encoding($true)))
}

# --- scenario helpers -----------------------------------------------------------
function Rdg([string]$Label, $Value, [string]$Unit = "") {
    $h = @{ label = $Label; value = $Value }
    if ($Unit) { $h.unit = $Unit }
    return $h
}
function NewSc { param([object[]]$Set = @(), [object[]]$Remove = @(), [object[]]$Add = @(), [switch]$IGpu, [double]$Delay = 0, [switch]$Down)
    $h = @{}
    if ($Set.Count)    { $h.set = $Set }
    if ($Remove.Count) { $h.remove = $Remove }
    if ($Add.Count)    { $h.add = $Add }
    if ($IGpu)         { $h.igpu = $true }
    if ($Delay -gt 0)  { $h.delay = $Delay }
    if ($Down)         { $h.down = $true }
    return $h
}
function Write-Scenario($Sc) {
    [System.IO.File]::WriteAllText($ScFile, (ConvertTo-Json -InputObject $Sc -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}
function Reset-Work {
    if (Test-Path $LogDir) { Remove-Item $LogDir -Recurse -Force }
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    if (Test-Path $TaskLog) { Remove-Item $TaskLog -Force }
}
function Start-Guard([string[]]$GuardArgs) {
    # Where-Object drops $null/empty entries: Windows PowerShell 5.1 rejects an empty
    # string in -ArgumentList (an empty "no extra arguments" list unrolls to one).
    $argList = @('-NoProfile', '-File', "`"$Copy`"") + @($GuardArgs | Where-Object { $_ })
    $id = [guid]::NewGuid().ToString("N")   # one output file pair per process: two guards run at once in some tests
    $script:LastStderr = Join-Path $Root "stderr-$id.txt"
    $p = Start-Process -FilePath $Engine -ArgumentList $argList -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput (Join-Path $Root "stdout-$id.txt") -RedirectStandardError $script:LastStderr
    $null = $p.Handle   # keeps ExitCode readable after the process ended
    return $p
}
function Stop-Guard($p) {
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } ; [void]$p.WaitForExit(3000) }
}
function Get-GuardLog { if (Test-Path $LogFile) { return [System.IO.File]::ReadAllText($LogFile) } return "" }

# Runs the guard for up to $Duration seconds while the mock endpoint follows the timeline.
function Invoke-Guard {
    param([int]$Duration, [object[]]$Timeline, [hashtable]$EnvVars = @{}, [string[]]$GuardArgs = @('-DryRun'), [scriptblock]$Seed = $null)
    Reset-Work
    if ($Seed) { & $Seed }
    Write-Scenario $Timeline[0].Sc
    foreach ($k in $EnvVars.Keys) { Set-Item -Path "Env:$k" -Value $EnvVars[$k] }
    try { $p = Start-Guard $GuardArgs } finally { foreach ($k in $EnvVars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue } }
    $start = Get-Date
    $next  = 1
    while (-not $p.HasExited -and ((Get-Date) - $start).TotalSeconds -lt $Duration) {
        $el = ((Get-Date) - $start).TotalSeconds
        while ($next -lt $Timeline.Count -and $el -ge $Timeline[$next].At) { Write-Scenario $Timeline[$next].Sc; $next++ }
        Start-Sleep -Milliseconds 200
    }
    $exit = if ($p.HasExited) { $p.ExitCode } else { "running" }
    Stop-Guard $p
    Start-Sleep -Milliseconds 300
    $err = ""
    if ($script:LastStderr -and (Test-Path $script:LastStderr)) { $err = [System.IO.File]::ReadAllText($script:LastStderr) }
    return [pscustomobject]@{ Log = (Get-GuardLog); Exit = $exit; Stderr = $err }
}

function Get-LogTime([string]$Log, [string]$Pattern) {
    $m = [regex]::Match($Log, '(?m)^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\][^\r\n]*' + $Pattern)
    if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-Result($Res, $Spec) {
    $fail = New-Object System.Collections.ArrayList
    foreach ($re in @($Spec.Expect)) { if ($re -and $Res.Log -notmatch $re) { [void]$fail.Add("missing in log: $re") } }
    foreach ($re in @($Spec.Forbid)) { if ($re -and $Res.Log -match $re)    { [void]$fail.Add("must not appear: $re") } }
    if ($Spec.Counts) {
        foreach ($re in $Spec.Counts.Keys) {
            $n = ([regex]::Matches($Res.Log, $re)).Count
            $lo, $hi = $Spec.Counts[$re]
            if ($n -lt $lo -or $n -gt $hi) { [void]$fail.Add("'$re' found $n times, expected $lo..$hi") }
        }
    }
    if ($Spec.Order) {
        $a = [regex]::Match($Res.Log, $Spec.Order[0]); $b = [regex]::Match($Res.Log, $Spec.Order[1])
        if (-not $a.Success -or -not $b.Success) { [void]$fail.Add("order check: pattern missing ($($Spec.Order -join '  BEFORE  '))") }
        elseif ($a.Index -ge $b.Index) { [void]$fail.Add("wrong order, expected first: $($Spec.Order[0])  then: $($Spec.Order[1])") }
    }
    foreach ($tm in @($Spec.Timing)) {
        if (-not $tm) { continue }
        $t0 = Get-LogTime $Res.Log $tm.From; $t1 = Get-LogTime $Res.Log $tm.To
        if ($null -eq $t0 -or $null -eq $t1) { [void]$fail.Add("timing check: pattern missing ($($tm.From) / $($tm.To))"); continue }
        $d = ($t1 - $t0).TotalSeconds
        if ($d -lt $tm.Min -or $d -gt $tm.Max) { [void]$fail.Add("timing: '$($tm.To)' came $d s after '$($tm.From)', expected $($tm.Min)..$($tm.Max) s") }
    }
    if ($Spec.Check) { foreach ($x in @(& $Spec.Check $Res)) { if ($x -is [string]) { [void]$fail.Add($x) } } }
    $wantExit = if ($Spec.Exit) { $Spec.Exit } else { "running" }
    if ($wantExit -eq "self") { if ($Res.Exit -ne 0) { [void]$fail.Add("expected the script to end by itself with exit 0, got: $($Res.Exit)") } }
    elseif ($Res.Exit -ne "running") { [void]$fail.Add("expected the script to keep running, but it ended (exit $($Res.Exit))") }
    if ($Res.Stderr -match 'ParserError|Unexpected token') { [void]$fail.Add("PowerShell parse error on stderr") }
    return $fail
}

# --- scenarios --------------------------------------------------------------------
$FansRun  = @((Rdg 'GPU Fan1' 900 'RPM'), (Rdg 'GPU Fan2' 900 'RPM'), (Rdg 'GPU Core Load' 60))
$FansStop = @((Rdg 'GPU Fan1' 0 'RPM'),   (Rdg 'GPU Fan2' 0 'RPM'),   (Rdg 'GPU Core Load' 60))
$Hot      = NewSc -Set @(Rdg 'GPU Memory Junction Temperature' 101)
$Gone     = NewSc -Remove @(@{ label = 'GPU Memory Junction Temperature' })

$Scenarios = @(
    @{ Name = 'baseline'; Duration = 8; Timeline = @(@{ At = 0; Sc = (NewSc) })
       Expect = @('GPU sensor index: sensorIndex 10 resolved', 'HEALTHY: first successful sensor poll', 'Security +\[(OK|WARN)\]')
       Forbid = @('threw', 'CRITICAL', 'Temps back to normal', 'FATAL') }

    @{ Name = 'stage-timing-compensates-for-slow-polls'; Duration = 26; Exit = 'self'; Env = @{ TG_POLL = '3' }
       Timeline = @(@{ At = 0; Sc = (NewSc -Set @(Rdg 'GPU Memory Junction Temperature' 101) -Delay 2) })
       Expect = @('stage 3: SHUTDOWN')
       Timing = @(@{ From = 'GPU Memory Junction: CRITICAL value'; To = 'GPU Memory Junction: \d+s critical, stage 2'; Min = 5; Max = 8 }) }

    @{ Name = 'fan-zero-rpm-cool-gpu-no-alarm'; Duration = 22
       Timeline = @(@{ At = 0; Sc = (NewSc -Set ($FansRun  + (Rdg 'GPU Temperature' 45))) }, @{ At = 3; Sc = (NewSc -Set ($FansStop + (Rdg 'GPU Temperature' 45))) })
       Forbid = @('GPU Fan( 2)?: CRITICAL', 'critical, stage [23]') }

    @{ Name = 'fan-dead-and-hot-escalates'; Duration = 30; Exit = 'self'
       Timeline = @(@{ At = 0; Sc = (NewSc -Set ($FansRun  + (Rdg 'GPU Temperature' 70))) }, @{ At = 3; Sc = (NewSc -Set ($FansStop + (Rdg 'GPU Temperature' 70))) })
       Expect = @('GPU Fan: CRITICAL', 'GPU Fan: \d+s critical, stage 2', 'stage 3: SHUTDOWN') }

    @{ Name = 'sensor-vanishes-while-critical'; Duration = 30; Exit = 'self'
       Timeline = @(@{ At = 0; Sc = $Hot }, @{ At = 4; Sc = $Gone })
       Expect = @('presuming it is still critical', 'GPU Memory Junction: \d+s critical, stage 3: SHUTDOWN') }

    @{ Name = 'endpoint-down-while-critical'; Duration = 30; Exit = 'self'
       Timeline = @(@{ At = 0; Sc = $Hot }, @{ At = 4; Sc = (NewSc -Down) })
       Expect = @('no sensor data at all while its critical timer is running', 'GPU Memory Junction: \d+s critical, stage 3: SHUTDOWN') }

    @{ Name = 'sensor-returns-normal-resets-timer'; Duration = 16
       Timeline = @(@{ At = 0; Sc = $Hot }, @{ At = 3; Sc = $Gone }, @{ At = 6; Sc = (NewSc -Set @(Rdg 'GPU Memory Junction Temperature' 60)) })
       Expect = @('presuming it is still critical', 'value normalized \(60\)'); Forbid = @('stage [23]: ', 'critical, stage [23]') }

    @{ Name = 'implausible-value-while-critical'; Duration = 30; Exit = 'self'
       Timeline = @(@{ At = 0; Sc = $Hot }, @{ At = 3; Sc = (NewSc -Set @(Rdg 'GPU Memory Junction Temperature' 999)) })
       Expect = @('IMPLAUSIBLE value 999', 'presuming it is still critical', 'stage 3: SHUTDOWN') }

    @{ Name = 'missing-sensor-without-timer-only-alerts'; Duration = 8; Timeline = @(@{ At = 0; Sc = $Gone })
       Expect = @('Sensor missing: GPU Memory Junction'); Forbid = @('presuming', 'CRITICAL', 'critical, stage') }

    @{ Name = 'loop-gap-resets-timers'; Duration = 22; Env = @{ TG_GAP = '4' }
       Timeline = @(@{ At = 0; Sc = $Hot }, @{ At = 3; Sc = (NewSc -Set @(Rdg 'GPU Memory Junction Temperature' 101) -Delay 8) })
       Expect = @('Main loop gap of \d+s'); Forbid = @('stage 3: SHUTDOWN') }

    @{ Name = 'exceptions-are-contained-protection-continues'; Duration = 30; Exit = 'self'
       Env = @{ TG_FAULT = 'digest,sensor' }; GuardArgs = @('-SimulateTemp', '95'); Timeline = @(@{ At = 0; Sc = (NewSc) })
       Expect = @("Subsystem 'Info-alert digest' threw", "Subsystem 'Sensor GPU Memory Junction' threw", 'CPU Tctl/Tdie: \d+s critical, stage 3: SHUTDOWN')
       Forbid = @('FATAL') }

    @{ Name = 'repeated-error-is-rate-limited'; Duration = 12; Env = @{ TG_FAULT = 'digest' }; Timeline = @(@{ At = 0; Sc = (NewSc) })
       Counts = @{ "Subsystem 'Info-alert digest' threw" = @(1, 1) } }

    @{ Name = 'digest-no-spam-for-changing-values'; Duration = 10
       Timeline = @(@{ At = 0; Sc = (NewSc -Add @(@{ label = 'Test SSD Temperature'; sensorIndex = 6; value = @{ jitter = @(80, 3) } })) })
       Counts = @{ 'Info-alert queued' = @(1, 1) }
       Expect = @('Test SSD Temperature: [0-9.]+ C; GPU Power: ') }

    @{ Name = 'perf-limit-flags-alert'; Duration = 8
       Timeline = @(@{ At = 0; Sc = (NewSc -Set @((Rdg 'Performance Limit - Power' 1), (Rdg 'Performance Limit - Thermal' 1))) })
       Counts = @{ 'Performance Limit - (Power|Thermal) ACTIVE' = @(2, 2) } }

    @{ Name = 'igpu-plus-dgpu-picks-the-dedicated-gpu'; Duration = 7; Timeline = @(@{ At = 0; Sc = (NewSc -IGpu) })
       Expect = @('sensorIndex 10 resolved from live sensor data \(2 candidate', "GPU Temperature -> labelOriginal='GPU Temperature' sensorIndex=10 ")
       Forbid = @("GPU Temperature -> labelOriginal='GPU Temperature' sensorIndex=3 ") }

    @{ Name = 'crit-hysteresis-hovering-value-still-escalates'; Duration = 30; Exit = 'self'
       Timeline = @(@{ At = 0; Sc = (NewSc -Set @(Rdg 'GPU Memory Junction Temperature' @{ jitter = @(98.5, 3) })) })
       Expect = @('GPU Memory Junction: \d+s critical, stage 3: SHUTDOWN'); Forbid = @('GPU Memory Junction: value normalized') }

    @{ Name = 'shutdown-starts-before-the-alert'; Duration = 30; Exit = 'self'; GuardArgs = @()
       Timeline = @(@{ At = 0; Sc = $Hot })
       Expect = @('\[TEST\] shutdown\.exe /s /f /t 10', 'kill stage 2 \(stubbed\)')
       Order = @('\[TEST\] shutdown\.exe', 'EMERGENCY SHUTDOWN \|') }

    @{ Name = 'failsafe-shutdown-is-recorded'; Duration = 25; Exit = 'self'; GuardArgs = @()
       Env = @{ TG_FS_STAGE2 = '2'; TG_FS_SHUTDOWN = '6' }; Timeline = @(@{ At = 0; Sc = (NewSc -Down) })
       Expect = @('Data-loss fail-safe: blind for \d+s, SHUTDOWN', '\[TEST\] shutdown\.exe /s /f /t 10')
       Forbid = @('Boot-loop breaker ACTIVE')
       Check = { param($r) $f = Join-Path $LogDir 'failsafe-shutdowns.txt'
                 if (-not (Test-Path $f)) { 'the fail-safe shutdown was not recorded in failsafe-shutdowns.txt' }
                 elseif (@(Get-Content $f).Count -ne 1) { "expected 1 recorded shutdown, found $(@(Get-Content $f).Count)" } } }

    @{ Name = 'failsafe-boot-loop-breaker-suppresses-the-shutdown'; Duration = 16; GuardArgs = @()
       Env = @{ TG_FS_STAGE2 = '2'; TG_FS_SHUTDOWN = '6' }; Timeline = @(@{ At = 0; Sc = (NewSc -Down) })
       Seed = { Set-Content -Path (Join-Path $LogDir 'failsafe-shutdowns.txt') -Value @((Get-Date).AddMinutes(-5).ToString('o'), (Get-Date).AddMinutes(-12).ToString('o')) -Encoding ASCII }
       Expect = @('Boot-loop breaker ACTIVE', 'shutdown SUPPRESSED by the boot-loop breaker')
       Forbid = @('\[TEST\] shutdown\.exe') }

    @{ Name = 'failsafe-old-shutdowns-do-not-count'; Duration = 25; Exit = 'self'; GuardArgs = @()
       Env = @{ TG_FS_STAGE2 = '2'; TG_FS_SHUTDOWN = '6' }; Timeline = @(@{ At = 0; Sc = (NewSc -Down) })
       Seed = { Set-Content -Path (Join-Path $LogDir 'failsafe-shutdowns.txt') -Value @((Get-Date).AddHours(-3).ToString('o'), (Get-Date).AddHours(-4).ToString('o')) -Encoding ASCII }
       Expect = @('\[TEST\] shutdown\.exe /s /f /t 10'); Forbid = @('Boot-loop breaker ACTIVE') }

    @{ Name = 'failsafe-history-is-cleared-by-a-healthy-poll'; Duration = 8; GuardArgs = @(); Timeline = @(@{ At = 0; Sc = (NewSc) })
       Seed = { Set-Content -Path (Join-Path $LogDir 'failsafe-shutdowns.txt') -Value @((Get-Date).AddMinutes(-5).ToString('o'), (Get-Date).AddMinutes(-12).ToString('o')) -Encoding ASCII }
       Expect = @('Boot-loop breaker ACTIVE', 'HEALTHY: first successful sensor poll')
       Check = { param($r) if (Test-Path (Join-Path $LogDir 'failsafe-shutdowns.txt')) { 'the history was not cleared by the healthy poll' } } }
)

# --- custom tests (need more than one process or no mock data) ---------------------
$Custom = @(
    @{ Name = 'second-instance-exits-dryrun-is-exempt'; Run = {
        $f = New-Object System.Collections.ArrayList
        Reset-Work; Write-Scenario (NewSc)
        $a = Start-Guard @()
        try {
            Start-Sleep -Seconds 5
            $b = Start-Guard @()
            [void]$b.WaitForExit(15000)
            if (-not $b.HasExited) { [void]$f.Add("a second real instance did not exit"); Stop-Guard $b }
            elseif ($b.ExitCode -ne 0) { [void]$f.Add("second instance exit code $($b.ExitCode), expected 0") }
            if ($a.HasExited) { [void]$f.Add("the first instance died") }
            if ((Get-GuardLog) -notmatch 'Another ThermalGuard instance is already running') { [void]$f.Add("missing log line: Another ThermalGuard instance is already running") }
            $c = Start-Guard @('-DryRun')
            Start-Sleep -Seconds 4
            if ($c.HasExited) { [void]$f.Add("a -DryRun instance must NOT be blocked by the mutex, but it ended") }
            Stop-Guard $c
        } finally { Stop-Guard $a }
        return $f } }

    @{ Name = 'installer-re-enables-the-task-after-a-failed-install'; Run = {
        $f = New-Object System.Collections.ArrayList
        Reset-Work; Write-Scenario (NewSc)
        $pending = Join-Path $Root "tg.pending-v9.9.ps1"
        Set-Content -Path $pending -Value '# staged test update' -Encoding ASCII
        Set-Content -Path "$pending.sha256" -Value (Get-FileHash -Path $pending -Algorithm SHA256).Hash.ToLowerInvariant() -Encoding ASCII
        $env:TG_FAKETASK = '1'; $env:TG_TASKLOG = $TaskLog; $env:TG_FAULT = 'stopproc'
        try { $p = Start-Guard @('-InstallPendingUpdate'); [void]$p.WaitForExit(40000) }
        finally { Remove-Item Env:TG_FAKETASK, Env:TG_TASKLOG, Env:TG_FAULT -ErrorAction SilentlyContinue }
        if (-not $p.HasExited) { [void]$f.Add("installer did not finish"); Stop-Guard $p }
        $tl = if (Test-Path $TaskLog) { @(Get-Content $TaskLog) } else { @() }
        if (($tl -join ',') -notmatch 'DISABLE.*ENABLE') { [void]$f.Add("scheduled task was not re-enabled after the failed install (task calls: $($tl -join ', '))") }
        return $f } }

    @{ Name = 'guard-process-detection-needs-name-and-file-argument'; Run = {
        $f = New-Object System.Collections.ArrayList
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errs)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-IsGuardProcess' }, $true)
        if (-not $fn) { [void]$f.Add("function Test-IsGuardProcess does not exist"); return $f }
        Invoke-Expression $fn.Extent.Text
        $cases = @(
            @{ n = 'pwsh.exe';       c = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File "C:\Tools\HWiNFO-ThermalGuard\HWiNFO-ThermalGuard.ps1"'; want = $true }
            @{ n = 'powershell.exe'; c = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\HWiNFO-ThermalGuard.ps1'; want = $true }
            @{ n = 'Code.exe';       c = '"C:\Code.exe" -File C:\Tools\HWiNFO-ThermalGuard.ps1'; want = $false }
            @{ n = 'notepad.exe';    c = 'notepad.exe C:\Tools\HWiNFO-ThermalGuard\HWiNFO-ThermalGuard.ps1'; want = $false }
            @{ n = 'pwsh.exe';       c = 'pwsh.exe -Command "Get-Content HWiNFO-ThermalGuard.ps1"'; want = $false }
            @{ n = 'pwsh.exe';       c = 'pwsh.exe -File C:\other\Something-Else.ps1'; want = $false }
        )
        foreach ($c in $cases) {
            $got = [bool](Test-IsGuardProcess -Name $c.n -CommandLine $c.c)
            if ($got -ne $c.want) { [void]$f.Add("$($c.n) / $($c.c): expected $($c.want), got $got") }
        }
        return $f } }

    @{ Name = 'remotehwinfo-download-must-match-the-pinned-hash'; Run = {
        $f = New-Object System.Collections.ArrayList
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errs)
        foreach ($n in 'Find-Executable', 'Resolve-RemoteHWInfo') {
            $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
            if (-not $fn) { [void]$f.Add("function $n not found"); return $f }
            Invoke-Expression $fn.Extent.Text
        }
        $work = Join-Path $Root "rhw"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        # a ZIP that contains a believable RemoteHWInfo.exe (Find-Executable ignores files < 5000 bytes)
        $good = Join-Path $work "good.zip"
        $src  = Join-Path $work "src"; New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $src "RemoteHWInfo.exe"), (New-Object byte[] 9000))
        if (Test-Path $good) { Remove-Item $good -Force }
        Compress-Archive -Path (Join-Path $src "*") -DestinationPath $good
        $goodHash = (Get-FileHash $good -Algorithm SHA256).Hash.ToLowerInvariant()

        function Write-Log { param([string]$Message, [string]$Level = "INFO") $script:RhwLog += "[$Level] $Message`n" }
        function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) Copy-Item -Path $good -Destination $OutFile -Force }
        $RemoteHWInfoZipUrl = "https://example.invalid/RemoteHWInfo.zip"
        $script:RemoteHWInfo_Path = $null

        # 1) hash does not match -> refused, nothing unpacked
        $ToolsDir = Join-Path $work "tools1"
        $RemoteHWInfoZipSha256 = ("0" * 64)
        $script:RhwLog = ""
        $r1 = Resolve-RemoteHWInfo
        if ($r1) { [void]$f.Add("a download with the wrong hash was accepted ($r1)") }
        if (Get-ChildItem -Path $ToolsDir -Recurse -Filter "RemoteHWInfo.exe" -ErrorAction SilentlyContinue) { [void]$f.Add("the ZIP with the wrong hash was unpacked") }
        if ($script:RhwLog -notmatch 'does not match the pinned hash') { [void]$f.Add("no log line about the hash mismatch") }

        # 2) hash matches -> installed
        $ToolsDir = Join-Path $work "tools2"
        $RemoteHWInfoZipSha256 = $goodHash
        $script:RhwLog = ""
        $r2 = Resolve-RemoteHWInfo
        if (-not $r2 -or $r2 -notmatch 'RemoteHWInfo\.exe$') { [void]$f.Add("a download with the correct hash was not installed (result: $r2)") }
        if ($script:RhwLog -notmatch 'SHA-256 verified against the pinned value') { [void]$f.Add("no log line about the verified hash") }
        return $f } }

    @{ Name = 'exposure-check-flags-writable-folders-only'; Run = {
        $f = New-Object System.Collections.ArrayList
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errs)
        $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-WritableByStandardUsers' }, $true)
        if (-not $fn) { [void]$f.Add("function Get-WritableByStandardUsers does not exist"); return $f }
        Invoke-Expression $fn.Extent.Text
        # a folder the current user owns can be rewritten by any non-elevated program of that user
        $mine = Join-Path $Root "owned-by-me"; New-Item -ItemType Directory -Path $mine -Force | Out-Null
        if (-not (Get-WritableByStandardUsers -Path $mine)) { [void]$f.Add("a folder owned by the current user was not flagged: $mine") }
        foreach ($safe in @((Join-Path $env:SystemRoot 'System32'), $env:ProgramFiles)) {
            $why = Get-WritableByStandardUsers -Path $safe
            if ($why) { [void]$f.Add("$safe was flagged but is protected by default: $why") }
        }
        if (Get-WritableByStandardUsers -Path (Join-Path $Root "does-not-exist")) { [void]$f.Add("a missing path must not be flagged") }
        return $f } }

    # Regression test: "icacls <folder> /inheritance:r /grant:r ... /T" leaves every FILE with an
    # empty permission list (unreadable, not startable). Protect-Folder must not do that.
    @{ Name = 'protect-folder-keeps-the-files-usable'; Run = {
        $f = New-Object System.Collections.ArrayList
        $installer = Join-Path (Split-Path -Parent $PSScriptRoot) "Install-ScheduledTask.ps1"
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errs)
        $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Protect-Folder' }, $true)
        if (-not $fn) { [void]$f.Add("function Protect-Folder not found in Install-ScheduledTask.ps1"); return $f }
        Invoke-Expression $fn.Extent.Text

        $d = Join-Path $Root "protect-me"
        New-Item -ItemType Directory -Path (Join-Path $d "sub") -Force | Out-Null
        Set-Content -Path (Join-Path $d "tool.exe") -Value "x"
        Set-Content -Path (Join-Path $d "sub\data.txt") -Value "y"
        # the real-world starting point: an explicit full-control entry for the current user on the folder
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $null = & icacls.exe $d /grant "${me}:(OI)(CI)F" 2>&1

        $r = Protect-Folder -Path $d
        if ($r.FilesWithEmptyAcl -ne 0) { [void]$f.Add("$($r.FilesWithEmptyAcl) file(s) were left with an EMPTY permission list") }
        if (-not $r.PermissionsSet)     { [void]$f.Add("Protect-Folder reported that the permissions were not set") }
        $adminsSid = 'S-1-5-32-544'; $usersSid = 'S-1-5-32-545'
        foreach ($p in @($d, (Join-Path $d "tool.exe"), (Join-Path $d "sub\data.txt"))) {
            $acl = Get-Acl -LiteralPath $p
            $sids = @{}
            foreach ($rule in $acl.Access) { $sids[$rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value] = $rule }
            if (-not $sids.ContainsKey($adminsSid) -or ($sids[$adminsSid].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) { [void]$f.Add("$p : Administrators do not have full control") }
            if (-not $sids.ContainsKey($usersSid)) { [void]$f.Add("$p : Users have no read/execute entry") }
            elseif (($sids[$usersSid].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::WriteData) -ne 0) { [void]$f.Add("$p : Users can still write") }
        }
        # the explicit entry of the current user on the folder must be gone (only via Users/Administrators now)
        $meSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($rule in (Get-Acl -LiteralPath $d).Access) {
            if ($rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $meSid) { [void]$f.Add("the explicit entry of the current user was not removed from the folder") }
        }
        try { $null = Get-Content -LiteralPath (Join-Path $d "tool.exe") -ErrorAction Stop } catch { [void]$f.Add("a file in the protected folder can no longer be read: $($_.Exception.Message)") }
        return $f } }
)

# --- run ----------------------------------------------------------------------------
$all = @($Scenarios | ForEach-Object { $_.Name }) + @($Custom | ForEach-Object { $_.Name })
if ($List) { $all; return }
function Test-Selected($name) {
    if (-not $Only -or $Only.Count -eq 0) { return $true }
    foreach ($pat in $Only) { if ($name -like $pat) { return $true } }
    return $false
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Write-Host "Script under test : $ScriptPath"
Write-Host "Engine            : $Engine ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
Write-Host "Work folder       : $Root"
Write-Host ""

$results = New-Object System.Collections.ArrayList
$mockProc = $null
try {
    New-TestCopy
    Write-Scenario (NewSc)
    $mockProc = Start-Process -FilePath $Engine -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile', '-File', "`"$Mock`"", '-Port', $Port, '-ScenarioFile', "`"$ScFile`"", '-FixtureFile', "`"$Fixture`"")
    $up = $false
    for ($i = 0; $i -lt 40 -and -not $up; $i++) {
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); $up = $true } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $up) { throw "mock endpoint did not come up on port $Port (is the port in use?)" }

    foreach ($s in $Scenarios) {
        if (-not (Test-Selected $s.Name)) { continue }
        Write-Host ("running  {0} ..." -f $s.Name) -NoNewline
        # ContainsKey, not truthiness: an explicit empty list means "real mode, no -DryRun".
        $args2 = if ($s.ContainsKey('GuardArgs')) { $s.GuardArgs } else { @('-DryRun') }
        $envs  = if ($s.Env) { $s.Env } else { @{} }
        $res   = Invoke-Guard -Duration $s.Duration -Timeline $s.Timeline -EnvVars $envs -GuardArgs $args2 -Seed $s.Seed
        $fail  = Test-Result $res $s
        [void]$results.Add([pscustomobject]@{ Name = $s.Name; Failures = $fail; Log = $res.Log })
        if ($fail.Count -eq 0) { Write-Host "`r[PASS] $($s.Name)                                        " -ForegroundColor Green }
        else {
            Write-Host "`r[FAIL] $($s.Name)                                        " -ForegroundColor Red
            foreach ($x in $fail) { Write-Host "         - $x" -ForegroundColor Red }
        }
    }
    foreach ($s in $Custom) {
        if (-not (Test-Selected $s.Name)) { continue }
        Write-Host ("running  {0} ..." -f $s.Name) -NoNewline
        $fail = @(& $s.Run) | Where-Object { $_ -is [string] }
        [void]$results.Add([pscustomobject]@{ Name = $s.Name; Failures = $fail; Log = (Get-GuardLog) })
        if ($fail.Count -eq 0) { Write-Host "`r[PASS] $($s.Name)                                        " -ForegroundColor Green }
        else {
            Write-Host "`r[FAIL] $($s.Name)                                        " -ForegroundColor Red
            foreach ($x in $fail) { Write-Host "         - $x" -ForegroundColor Red }
        }
    }
}
finally {
    if ($mockProc -and -not $mockProc.HasExited) { try { $mockProc.Kill() } catch { } }
    if (-not $KeepFiles -and (Test-Path $Root)) { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($results | Where-Object { $_.Failures.Count -gt 0 })
Write-Host ""
Write-Host ("{0} scenario(s), {1} passed, {2} failed" -f $results.Count, ($results.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
exit $failed.Count
