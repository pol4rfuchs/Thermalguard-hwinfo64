#requires -Version 5.1
# ============================================================================
# Approve-ThermalGuardUpdate.ps1
#
# Run this manually (double-click, or "Run with PowerShell") whenever
# ThermalGuard has staged an update and alerted you about it ("ThermalGuard
# update staged" toast/ntfy). It performs the actual install: stops the
# running instance, swaps the validated staged file into place, restarts it,
# and automatically rolls back to the previous working version if the new
# one does not come up healthy within the configured timeout.
#
# This is intentionally just a one-line wrapper. All of the actual
# stop/swap/restart/health-check/rollback logic lives in
# HWiNFO-ThermalGuard.ps1 itself (Install-ThermalGuardUpdate), invoked here
# via its own -InstallPendingUpdate switch - so there is exactly one place
# that logic is maintained, not two copies that can drift apart.
#
# This script must live in the same folder as HWiNFO-ThermalGuard.ps1.
#
# Nothing happens if no update is currently staged; it just logs that and
# exits. Safe to run at any time, including when you are not sure whether
# an update is actually waiting.
# ============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $ScriptDir "HWiNFO-ThermalGuard.ps1"

if (-not (Test-Path $MainScript)) {
    Write-Host "ERROR: $MainScript not found." -ForegroundColor Red
    Write-Host "This script must live in the same folder as HWiNFO-ThermalGuard.ps1." -ForegroundColor Red
    exit 1
}

Write-Host "=== ThermalGuard Update Approval ===" -ForegroundColor Cyan
Write-Host "Running the installer. This will briefly stop and restart the" -ForegroundColor Cyan
Write-Host "ThermalGuard scheduled task. If the update does not come up" -ForegroundColor Cyan
Write-Host "healthy within the configured timeout, it will roll back" -ForegroundColor Cyan
Write-Host "automatically to the previous version." -ForegroundColor Cyan
Write-Host ""

& $MainScript -InstallPendingUpdate

Write-Host ""
Write-Host "Done. Check thermalguard.log in %USERPROFILE%\HWiNFO-ThermalGuard\ for details." -ForegroundColor Cyan
