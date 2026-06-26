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
# This script is pure ASCII for the same reason as HWiNFO-ThermalGuard.ps1.
# ============================================================================

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
$Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

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
Write-Host "Test it now without logging off: " -NoNewline
Write-Host "Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
