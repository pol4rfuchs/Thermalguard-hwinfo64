#requires -Version 5.1
# ============================================================================
# ThermalGuard - Sensor Dump Helper
#
# Purpose: collect the HWiNFO / RemoteHWInfo sensor readings needed to add
# Intel CPU / AMD GPU / Intel Arc support to ThermalGuard.
#
# What this does:
#   - Polls the local RemoteHWInfo JSON endpoint (same one ThermalGuard uses)
#     repeatedly over a time window (minimum 120 seconds) instead of a single
#     snapshot, so it catches both idle values AND the spike when a game
#     starts. Start this script, then launch a game (or just wait it out for
#     idle-only) - either way it keeps sampling until the window is up.
#   - Tracks the PEAK value seen per reading across the whole window
#   - Copies the result to your clipboard AND saves it to a .txt file
#   - Does NOT send anything anywhere on its own. You decide what to paste
#     into the GitHub issue.
#
# What it does NOT do:
#   - No network calls except to localhost:60000 (your own PC)
#   - No system info beyond sensor labels/values (no username, no serials,
#     no drive/network identifiers) - see the filter below if your setup
#     exposes something unexpected, review the output before pasting.
#
# Usage:
#   1. Make sure HWiNFO64 + RemoteHWInfo are running (same as for ThermalGuard)
#   2. Run: .\Get-SensorDump.ps1
#      Optionally: .\Get-SensorDump.ps1 -DurationSeconds 180
#   3. While it's running, start a game or some load if you want peak values
#      under load captured too (recommended - idle alone often isn't enough)
#   4. Paste the clipboard content into the GitHub issue, or attach the
#      generated .txt file
# ============================================================================

param(
    # Minimum 120s so both idle and a game's startup spike get captured.
    [int]$DurationSeconds = 120
)

if ($DurationSeconds -lt 120) {
    Write-Host "DurationSeconds raised to the 120s minimum (idle + game-start needs that much)." -ForegroundColor Yellow
    $DurationSeconds = 120
}

$HWiNFO_URL   = "http://localhost:60000/json.json"
$PollInterval = 5
$OutFile      = Join-Path $env:USERPROFILE "Desktop\ThermalGuard-SensorDump.txt"

# Basic privacy filter: drop anything that looks like it could contain a
# serial number, MAC address, or drive/volume identifier rather than a
# plain sensor value. Sensor labels/temps/clocks/power/fan readings are
# unaffected by this - review the saved file yourself before sharing either
# way.
$blockPattern = '(?i)serial|mac address|uuid|volume'

# Fail fast instead of silently retrying for the full window: if RemoteHWInfo
# isn't even running yet, every poll below is guaranteed to fail anyway.
# ThermalGuard.ps1 (or the .bat launcher) needs to be started FIRST and left
# running - this script only reads the endpoint, it doesn't start anything.
if (-not (Get-Process RemoteHWInfo -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: RemoteHWInfo is not running." -ForegroundColor Red
    Write-Host "Start HWiNFO-ThermalGuard.ps1 (or Start-HWiNFO-Remote.bat) first and leave it running," -ForegroundColor Yellow
    Write-Host "then run this script in a second console." -ForegroundColor Yellow
    exit 1
}

# Keyed by "sensorIndex|readingId" -> object tracking the peak value seen.
$peakValues = @{}

$endTime = (Get-Date).AddSeconds($DurationSeconds)
Write-Host "Sampling sensors for $DurationSeconds seconds from $HWiNFO_URL ..." -ForegroundColor Cyan
Write-Host "Start a game now if you want load values captured too." -ForegroundColor Cyan

$gotAnyData = $false

while ((Get-Date) -lt $endTime) {
    try {
        $response = Invoke-RestMethod -Uri $HWiNFO_URL -TimeoutSec 5
    } catch {
        Write-Host "  poll failed (endpoint not reachable), retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds $PollInterval
        continue
    }

    $readings = $response.hwinfo.readings
    if (-not $readings -or $readings.Count -eq 0) {
        Start-Sleep -Seconds $PollInterval
        continue
    }
    $gotAnyData = $true

    foreach ($r in $readings) {
        if (([string]$r.labelOriginal) -match $blockPattern -or ([string]$r.labelUser) -match $blockPattern) {
            continue
        }
        $val = $null
        # Same locale bug as HWiNFO-ThermalGuard.ps1 had: the 2-arg TryParse
        # overload uses the current Windows culture and allows thousands-
        # grouping. On de-AT/de-DE systems "." is the thousands separator,
        # so RemoteHWInfo's own decimal-formatted values (it always emits
        # "602.000000" even for whole numbers) ALL fail to parse - which is
        # why a dump could come back with "Peak readings (0)" despite the
        # PC clearly having working sensors. Force invariant culture so
        # this works regardless of the machine's regional settings.
        if (-not [double]::TryParse(
                [string]$r.value,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$val)) { continue }

        $key = "$($r.sensorIndex)|$($r.readingId)"
        if (-not $peakValues.ContainsKey($key) -or $val -gt $peakValues[$key].PeakValue) {
            $peakValues[$key] = [PSCustomObject]@{
                LabelOriginal = $r.labelOriginal
                LabelUser     = $r.labelUser
                SensorIndex   = $r.sensorIndex
                ReadingId     = $r.readingId
                ReadingType   = $r.readingType
                Unit          = $r.unit
                PeakValue     = $val
            }
        }
    }

    $remaining = [int]([Math]::Ceiling(($endTime - (Get-Date)).TotalSeconds))
    if ($remaining -gt 0) {
        Write-Host "  ... $remaining s remaining" -ForegroundColor DarkGray
        Start-Sleep -Seconds ([Math]::Min($PollInterval, $remaining))
    }
}

if (-not $gotAnyData) {
    Write-Host "ERROR: Never got any readings. Is RemoteHWInfo fully started?" -ForegroundColor Red
    exit 1
}

$lines = @()
$lines += "=== ThermalGuard Sensor Dump ==="
$lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += "Sampling window: $DurationSeconds seconds (values below are the PEAK seen during that window)"
$lines += "PowerShell: $($PSVersionTable.PSVersion)"
$lines += ""
$lines += "Please also tell us in the GitHub issue:"
$lines += "  - CPU model (e.g. Intel Core i7-14700K / AMD Ryzen 7 9800X3D)"
$lines += "  - GPU model (e.g. Intel Arc B580 / AMD RX 9070 XT)"
$lines += "  - Whether you had a game/load running during the sampling window"
$lines += ""
$lines += "--- Peak readings ($($peakValues.Count)) ---"

foreach ($p in ($peakValues.Values | Sort-Object LabelOriginal)) {
    $lines += "labelOriginal='$($p.LabelOriginal)' | sensorIndex=$($p.SensorIndex) | readingId=$($p.ReadingId) | readingType=$($p.ReadingType) | unit='$($p.Unit)' | peakValue=$($p.PeakValue)"
}

$text = $lines -join "`r`n"

try {
    $text | Set-Clipboard
    Write-Host "Copied $($peakValues.Count) readings to clipboard." -ForegroundColor Green
} catch {
    Write-Host "Could not copy to clipboard (Set-Clipboard unavailable), continuing anyway." -ForegroundColor Yellow
}

$text | Out-File -FilePath $OutFile -Encoding UTF8
Write-Host "Also saved to: $OutFile" -ForegroundColor Green
Write-Host ""
Write-Host "Next step: paste the clipboard content into the GitHub issue," -ForegroundColor Cyan
Write-Host "or attach the .txt file from your Desktop." -ForegroundColor Cyan

