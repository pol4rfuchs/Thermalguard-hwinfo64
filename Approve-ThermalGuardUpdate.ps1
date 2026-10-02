#requires -Version 5.1
# ============================================================================
# Approve-ThermalGuardUpdate.ps1
#
# Manual approval step for a staged ThermalGuard update.
#
# With $EnableAutoDownload = $true the guard downloads a new release, checks
# its SHA-256 and its syntax, and stages it next to the live script as
#   HWiNFO-ThermalGuard.pending-vX.Y.ps1   (+ .sha256 with the verified hash)
# It does NOT put it live. This script shows what is staged and, after your
# confirmation, runs the installer of the live script (-InstallPendingUpdate):
#   verify -> back up the live file -> stop the guard -> swap -> restart ->
#   wait for the guard's health marker -> roll back automatically if it does
#   not come up healthy.
#
# Run it from an ELEVATED PowerShell (the guard itself runs elevated), in the
# folder where HWiNFO-ThermalGuard.ps1 lives:
#   powershell -ExecutionPolicy Bypass -File .\Approve-ThermalGuardUpdate.ps1
#
# Do not install while the PC is hot or under heavy load: between stopping the
# old guard and the first poll of the new one (normally well under a minute)
# nothing is monitoring the temperatures.
#
# -ListOnly  shows what is staged and checks it, installs nothing.
# -Yes       skips the confirmation question.
#
# This script is pure ASCII for the same reason as HWiNFO-ThermalGuard.ps1.
# ============================================================================

param(
    [switch]$Yes,
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LivePath  = Join-Path $ScriptDir "HWiNFO-ThermalGuard.ps1"
$BaseName  = "HWiNFO-ThermalGuard"
$LogFile   = Join-Path $env:USERPROFILE "HWiNFO-ThermalGuard\thermalguard.log"

Write-Host "=== HWiNFO Thermal Guard - approve staged update ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $LivePath)) {
    Write-Host "ERROR: $LivePath not found. Run this script from the ThermalGuard folder." -ForegroundColor Red
    exit 1
}

# --- find the staged update (highest version wins) ----------------------------
function Get-FileVersion([string]$Name) {
    if ($Name -match '-v([\d\.]+?)\.ps1$') { try { return [version]$matches[1] } catch { } }
    return [version]'0.0'
}
$pending = Get-ChildItem -Path (Join-Path $ScriptDir "$BaseName.pending-v*.ps1") -ErrorAction SilentlyContinue |
           Sort-Object -Property @{ Expression = { Get-FileVersion $_.Name }; Descending = $true } |
           Select-Object -First 1
if (-not $pending) {
    Write-Host "No staged update found in $ScriptDir." -ForegroundColor Yellow
    Write-Host "(An update gets staged when `$EnableUpdateCheck and `$EnableAutoDownload are on and a newer release exists.)"
    exit 0
}
$newVersion = Get-FileVersion $pending.Name

# --- what is running now ------------------------------------------------------
$curVersion = "unknown"
$verLine = Select-String -Path $LivePath -Pattern '^\$ScriptVersion\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($verLine) { $curVersion = $verLine.Matches[0].Groups[1].Value }

# --- checks on the staged file ------------------------------------------------
$actualHash = (Get-FileHash -Path $pending.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$sidecar    = "$($pending.FullName).sha256"
$hashState  = "NO recorded hash (UNVERIFIED)"
$hashOk     = $false
if (Test-Path $sidecar) {
    $expected = ([string](Get-Content -Path $sidecar -TotalCount 1)).Trim().ToLowerInvariant()
    if ($expected -eq $actualHash) { $hashState = "matches the hash recorded at download time (VERIFIED)"; $hashOk = $true }
    else                           { $hashState = "DOES NOT MATCH the recorded hash - file was modified after download!" }
}

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($pending.FullName, [ref]$tokens, [ref]$errors)
$syntaxOk = (-not $errors -or $errors.Count -eq 0)

Write-Host "Running version : $curVersion"
Write-Host "Staged version  : $newVersion  ($($pending.Name), $($pending.Length) bytes)"
Write-Host "SHA-256         : $actualHash"
Write-Host -NoNewline "Hash check      : "
if ($hashOk) { Write-Host $hashState -ForegroundColor Green } else { Write-Host $hashState -ForegroundColor Yellow }
Write-Host -NoNewline "Syntax check    : "
if ($syntaxOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "ERRORS - will not install" -ForegroundColor Red }
Write-Host ""

if (-not $syntaxOk) {
    foreach ($e in $errors) { Write-Host "  line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
    exit 1
}
if (Test-Path $sidecar) {
    if (-not $hashOk) { exit 1 }
} else {
    Write-Host "This file has no .sha256 sidecar. Compare the SHA-256 above with the one on the GitHub release page yourself." -ForegroundColor Yellow
    Write-Host "(The installer refuses it unless `$UpdateRequireHash is `$false in HWiNFO-ThermalGuard.ps1.)" -ForegroundColor Yellow
    Write-Host ""
}

if ($ListOnly) { exit 0 }

# --- elevation ---------------------------------------------------------------
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script must be run as Administrator (open an elevated PowerShell first)." -ForegroundColor Red
    exit 1
}

if (-not $Yes) {
    $answer = Read-Host "Install v$newVersion now? The guard restarts; it rolls back automatically if the new version does not come up healthy. [y/N]"
    if ($answer -notmatch '^(?i)y(es)?$') {
        Write-Host "Cancelled. Nothing was changed."
        exit 0
    }
}

# --- run the installer of the LIVE script ---------------------------------------
$engine = $null
$pwsh7  = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
if (Test-Path $pwsh7) { $engine = $pwsh7 } else { $engine = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe" }

Write-Host ""
Write-Host "Running the installer (this can take up to ~90 s while it waits for the new version)..." -ForegroundColor Cyan
& $engine -NoProfile -ExecutionPolicy Bypass -File $LivePath -InstallPendingUpdate

Write-Host ""
Write-Host "--- last update lines from the log ---" -ForegroundColor Cyan
if (Test-Path $LogFile) {
    Get-Content $LogFile -Tail 80 | Where-Object { $_ -match 'Update install' } | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
}
Write-Host ""
Write-Host "Check the last lines: '[OK] ... is up and healthy' = done, 'Rolling back' = the previous version was restored." -ForegroundColor Yellow
