#requires -Version 5.1
# ============================================================================
# Install-ScheduledTask.ps1
#
# Run this ONCE, manually, as Administrator (right-click -> Run with
# PowerShell, or "Run as administrator" from an elevated prompt). It
# registers a Scheduled Task that starts Start-HWiNFO-Remote.vbs at logon
# with highest privileges already granted by the task itself.
#
# Why this exists (report finding #16): placing a UAC "runas" call inside
# an item in shell:startup means Windows will show an elevation prompt on
# every login that a human must click. In an unattended/AFK scenario that
# prompt is never answered, so the whole protection chain silently never
# starts. A Scheduled Task with "Run with highest privileges" checked
# grants elevation as part of the task's own definition, so no prompt is
# shown at logon time at all.
#
# Self-heal (v1.51): the task also repeats every -RepeatMinutes minutes
# (default 5, 0 = off). Each repetition just runs the launcher again; the
# launcher exits silently if the guard is already running and starts it if it
# died. Before, a crashed guard stayed dead until the next logon. The task
# settings keep "do not start a new instance" (IgnoreNew) as the default.
#
# This script is pure ASCII for the same reason as HWiNFO-ThermalGuard.ps1.
# ============================================================================

param(
    [int]$RepeatMinutes = 5
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VbsPath   = Join-Path $ScriptDir "Start-HWiNFO-Remote.vbs"
$TaskName  = "HWiNFO Thermal Guard"

Write-Host "=== HWiNFO Thermal Guard - Scheduled Task Setup ===" -ForegroundColor Cyan
Write-Host ""

# --- Require elevation -------------------------------------------------------
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click this file and choose 'Run with PowerShell' from an elevated prompt," -ForegroundColor Yellow
    Write-Host "or open an Administrator PowerShell window and run it from there." -ForegroundColor Yellow
    exit 1
}

# --- Verify the companion files exist ----------------------------------------
if (-not (Test-Path $VbsPath)) {
    Write-Host "ERROR: $VbsPath not found." -ForegroundColor Red
    Write-Host "This script must live in the same folder as Start-HWiNFO-Remote.vbs." -ForegroundColor Red
    exit 1
}

$BatPath = Join-Path $ScriptDir "Start-HWiNFO-Remote.bat"
$Ps1Path = Join-Path $ScriptDir "HWiNFO-ThermalGuard.ps1"
if (-not (Test-Path $BatPath)) {
    Write-Host "WARNING: $BatPath not found. The task will be created but will fail until it exists." -ForegroundColor Yellow
}
if (-not (Test-Path $Ps1Path)) {
    Write-Host "WARNING: $Ps1Path not found. The task will be created but will fail until it exists." -ForegroundColor Yellow
}

Write-Host "Folder:    $ScriptDir"
Write-Host "VBS:       $VbsPath"
Write-Host "Task name: $TaskName"
Write-Host ""

# --- Remove any previous registration of this task --------------------------
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Existing task found, removing it first..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# --- Register the new task ---------------------------------------------------
$Action    = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
$Trigger   = New-ScheduledTaskTrigger -AtLogOn
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

# --- Repetition (self-heal) ---------------------------------------------------
# An interval WITHOUT a duration repeats indefinitely (Task Scheduler schema:
# "If no value is specified for the duration, then the pattern is repeated
# indefinitely"). The cmdlet cannot combine -AtLogOn with a repetition, so the
# pattern is set on the trigger object directly. Both attempts are guarded:
# if neither works the task is still registered (logon start only) and the
# read-back below says so.
if ($RepeatMinutes -gt 0) {
    $repetitionSet = $false
    try {
        $patternClass = Get-CimClass -ClassName MSFT_TaskRepetitionPattern -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
        $Trigger.Repetition = New-CimInstance -CimClass $patternClass -ClientOnly -Property @{ Interval = ("PT{0}M" -f $RepeatMinutes) } -ErrorAction Stop
        $repetitionSet = $true
    } catch {
        Write-Host "Note: direct repetition pattern failed ($($_.Exception.Message)), trying the fallback..." -ForegroundColor Yellow
    }
    if (-not $repetitionSet) {
        try {
            # Fallback: borrow the pattern from a one-time trigger, with a very long (10 years) explicit duration.
            $once = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
            $Trigger.Repetition = $once.Repetition
            $repetitionSet = $true
        } catch {
            Write-Host "WARNING: could not set a repetition ($($_.Exception.Message)). The task will start at logon only." -ForegroundColor Yellow
        }
    }
}

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host "It will run at every logon for user '$env:USERNAME' with the rights this task" -ForegroundColor Green
Write-Host "was registered with - no UAC prompt will appear at logon time." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT: do NOT also place Start-HWiNFO-Remote.vbs in shell:startup." -ForegroundColor Yellow
Write-Host "Use either the Scheduled Task (this script) OR the startup folder, not both," -ForegroundColor Yellow
Write-Host "to avoid starting the chain twice." -ForegroundColor Yellow
Write-Host ""
# --- Read back what Task Scheduler actually stored -------------------------------
if ($RepeatMinutes -gt 0) {
    $stored = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $interval = $null
    if ($stored) { $interval = ($stored.Triggers | ForEach-Object { $_.Repetition.Interval } | Where-Object { $_ } | Select-Object -First 1) }
    if ($interval) {
        Write-Host "Self-heal: the launcher is re-run every $interval (ISO 8601) and exits silently while the guard is running." -ForegroundColor Green
    } else {
        Write-Host "WARNING: no repetition is stored on the task. A crashed guard will NOT be restarted until the next logon." -ForegroundColor Yellow
        Write-Host "         Check Task Scheduler -> '$TaskName' -> Triggers -> Edit -> 'Repeat task every'." -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "Test it now without logging off: " -NoNewline
Write-Host "Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
