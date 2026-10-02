#requires -Version 5.1
# ============================================================================
# Get-SensorDump.ps1
#
# Samples the HWiNFO sensor data that RemoteHWInfo serves and writes a compact
# report you can paste into a GitHub issue ("Sensor data" template). Its job is
# to give the exact sensor labels and units of hardware ThermalGuard does not
# support yet (Intel CPUs, Intel Arc GPUs, other boards), so the labels can be
# confirmed on real hardware instead of guessed.
#
# This script only READS. It never kills, restarts or shuts anything down.
#
# Prerequisite: HWiNFO64 + RemoteHWInfo must already be running (start
# HWiNFO-ThermalGuard.ps1 or the .bat launcher first and leave it running).
# If the endpoint cannot be reached the script stops at once with a clear
# message instead of retrying silently for the whole sampling time.
#
# Best result: start it, then put the PC under load (a game or a stress test)
# for the 120 seconds, so load- and temperature-dependent sensors show real
# values (min/avg/max are reported per sensor).
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\Get-SensorDump.ps1
# Options: -DurationSec 120   total sampling time (min 10)
#          -IntervalSec 2     seconds between samples (min 1)
#          -Url <endpoint>    default http://localhost:60000/json.json
#          -OutFile <path>    default %USERPROFILE%\HWiNFO-ThermalGuard\ThermalGuard-SensorDump.txt
#
# Privacy: the report contains hardware MODEL names (CPU, GPU, mainboard,
# drives and whatever else HWiNFO lists) but no user name, computer name or
# serial numbers. Read it before you post it and remove anything you do not
# want to publish.
#
# This script is pure ASCII for the same reason as HWiNFO-ThermalGuard.ps1.
# ============================================================================

param(
    [int]$DurationSec = 120,
    [int]$IntervalSec = 2,
    [string]$Url = "http://localhost:60000/json.json",
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$DumpVersion = "1.51"

if ($DurationSec -lt 10) { $DurationSec = 10 }
if ($IntervalSec -lt 1)  { $IntervalSec = 1 }
if (-not $OutFile) {
    $outDir = Join-Path $env:USERPROFILE "HWiNFO-ThermalGuard"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $OutFile = Join-Path $outDir "ThermalGuard-SensorDump.txt"
}

$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Snapshot {
    # Returns the "hwinfo" object or throws.
    $r = Invoke-RestMethod -Uri $Url -TimeoutSec 5 -ErrorAction Stop
    if (-not $r -or -not $r.hwinfo) { throw "Endpoint answered, but without a 'hwinfo' object." }
    return $r.hwinfo
}

function Show-WhyUnreachable {
    param([string]$Reason)
    Write-Host ""
    Write-Host "ERROR: could not read sensor data from $Url" -ForegroundColor Red
    Write-Host "       ($Reason)" -ForegroundColor Red
    Write-Host ""
    $hw = Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue
    $rh = Get-Process -Name RemoteHWInfo -ErrorAction SilentlyContinue
    if (-not $hw)  { Write-Host "  - HWiNFO64 is NOT running." -ForegroundColor Yellow }
    if (-not $rh)  { Write-Host "  - RemoteHWInfo is NOT running." -ForegroundColor Yellow }
    if ($hw -and $rh) {
        Write-Host "  - Both processes are running, but the endpoint does not answer with sensor data." -ForegroundColor Yellow
        Write-Host "    Check HWiNFO64 -> Settings -> 'Shared Memory Support' is enabled, then restart HWiNFO64." -ForegroundColor Yellow
    } else {
        Write-Host "  Start HWiNFO-ThermalGuard.ps1 (or Start-HWiNFO-Remote.bat) first and let it run, then start this script again." -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- first request: fail fast ---------------------------------------------------
try {
    $first = Get-Snapshot
} catch {
    Show-WhyUnreachable -Reason $_.Exception.Message
    exit 1
}
if (-not $first.readings -or @($first.readings).Count -eq 0) {
    Show-WhyUnreachable -Reason "reachable, but the reading list is empty"
    exit 1
}

Write-Host "=== ThermalGuard sensor dump v$DumpVersion ===" -ForegroundColor Cyan
Write-Host "Endpoint : $Url ($(@($first.readings).Count) readings)"
Write-Host "Sampling : every ${IntervalSec}s for ${DurationSec}s - put the PC under load now if you can (game / stress test)."
Write-Host ""

# --- sampling -------------------------------------------------------------------
$stats  = @{}      # key "sensorIndex|readingId" -> stats object
$order  = New-Object System.Collections.ArrayList
$sensorsById = @{}
$samples = 0
$failStreak = 0
$started = Get-Date
$nextReport = 10

function Add-Snapshot($snap) {
    foreach ($s in @($snap.sensors)) {
        if ($null -eq $s) { continue }
        $id = [string]$s.entryIndex
        if (-not $sensorsById.ContainsKey($id)) {
            $sensorsById[$id] = [string]$s.sensorNameOriginal
        }
    }
    foreach ($r in @($snap.readings)) {
        $key = "$($r.sensorIndex)|$($r.readingId)"
        if (-not $stats.ContainsKey($key)) {
            $stats[$key] = [pscustomobject]@{
                SensorIndex = [string]$r.sensorIndex
                Label       = [string]$r.labelOriginal
                LabelUser   = [string]$r.labelUser
                Unit        = [string]$r.unit
                Min         = [double]::PositiveInfinity
                Max         = [double]::NegativeInfinity
                Sum         = 0.0
                Count       = 0
                NonNumeric  = 0
                LastRaw     = ""
            }
            [void]$order.Add($key)
        }
        $st = $stats[$key]
        $st.LastRaw = [string]$r.value
        $num = 0.0
        # InvariantCulture on purpose: de-AT/de-DE systems misread "61.625" with the culture-dependent overload.
        if ([double]::TryParse([string]$r.value, [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) {
            if ($num -lt $st.Min) { $st.Min = $num }
            if ($num -gt $st.Max) { $st.Max = $num }
            $st.Sum += $num
            $st.Count++
        } else {
            $st.NonNumeric++
        }
    }
}

Add-Snapshot $first
$samples = 1

while (((Get-Date) - $started).TotalSeconds -lt $DurationSec) {
    Start-Sleep -Seconds $IntervalSec
    try {
        $snap = Get-Snapshot
        Add-Snapshot $snap
        $samples++
        $failStreak = 0
    } catch {
        $failStreak++
        Write-Host "  sample failed ($failStreak/3): $($_.Exception.Message)" -ForegroundColor Yellow
        if ($failStreak -ge 3) {
            Show-WhyUnreachable -Reason "3 failed requests in a row while sampling"
            Write-Host "Writing what was collected so far..." -ForegroundColor Yellow
            break
        }
    }
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($elapsed -ge $nextReport) {
        Write-Host ("  {0,3}s / {1}s  ({2} samples)" -f $elapsed, $DurationSec, $samples)
        $nextReport += 10
    }
}

# --- report ---------------------------------------------------------------------
function Format-Num([double]$d) {
    if ([double]::IsInfinity($d) -or [double]::IsNaN($d)) { return "-" }
    return $d.ToString("0.###", $inv)
}

function Format-Unit([string]$u) {
    # Show non-ASCII unit characters as code points: the exact degree-sign
    # character (and any encoding mix-up) is what the unit filter depends on.
    $nonAscii = @($u.ToCharArray() | Where-Object { [int]$_ -gt 127 })
    if ($nonAscii.Count -eq 0) { return $u }
    $codes = ($u.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' '
    return "$u [$codes]"
}

$sb = New-Object System.Text.StringBuilder
function Out-Line([string]$s) { [void]$sb.AppendLine($s) }

Out-Line "ThermalGuard sensor dump v$DumpVersion"
Out-Line "Date       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Out-Line "Sampling   : $samples samples over $([int]((Get-Date) - $started).TotalSeconds)s (interval ${IntervalSec}s)"
Out-Line "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
try { Out-Line ("OS         : " + (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption) } catch { Out-Line "OS         : unknown" }
try { Out-Line ("CPU        : " + ((Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object { $_.Name.Trim() }) -join ' | ')) } catch { Out-Line "CPU        : unknown" }
try {
    $gpuNames = Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft|Remote|Virtual' } | ForEach-Object { $_.Name }
    Out-Line ("GPU        : " + ($gpuNames -join ' | '))
} catch { Out-Line "GPU        : unknown" }
try { $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop; Out-Line ("Mainboard  : $($bb.Manufacturer) $($bb.Product)") } catch { Out-Line "Mainboard  : unknown" }
Out-Line "Readings   : $($order.Count)"
Out-Line ""
Out-Line "Privacy: this report lists hardware model names but no user or computer name. Review it before posting."
Out-Line "Columns per reading: label | unit | min | avg | max   (sensorIndex = the device the reading belongs to)"
Out-Line ""

$bySensor = $order | ForEach-Object { $stats[$_] } | Group-Object SensorIndex
foreach ($g in ($bySensor | Sort-Object { [int]($_.Name -as [int]) })) {
    $name = if ($sensorsById.ContainsKey($g.Name)) { $sensorsById[$g.Name] } else { "(no name in sensor list)" }
    Out-Line "[sensorIndex=$($g.Name)] $name"
    foreach ($st in $g.Group) {
        $label = $st.Label
        if ($st.LabelUser -and $st.LabelUser -ne $st.Label) { $label = "$label (user label: $($st.LabelUser))" }
        if ($st.Count -gt 0) {
            $avg = $st.Sum / $st.Count
            Out-Line ("  {0} | {1} | {2} | {3} | {4}" -f $label, (Format-Unit $st.Unit), (Format-Num $st.Min), (Format-Num $avg), (Format-Num $st.Max))
        } else {
            Out-Line ("  {0} | {1} | non-numeric, last value: {2}" -f $label, (Format-Unit $st.Unit), $st.LastRaw)
        }
    }
    Out-Line ""
}

$text = $sb.ToString()
Set-Content -Path $OutFile -Value $text -Encoding UTF8

Write-Host ""
Write-Host "Done. $($order.Count) readings, $samples samples." -ForegroundColor Green
Write-Host "Report written to:" -ForegroundColor Green
Write-Host "  $OutFile"
Write-Host ""
Write-Host "Next: open the file, check it, and paste it into the GitHub issue ('Sensor data' template)." -ForegroundColor Yellow
if ($text.Length -gt 60000) {
    Write-Host "Note: the report is $($text.Length) characters long; GitHub comments cap at 65,536. Attach the file instead of pasting it." -ForegroundColor Yellow
}
