#requires -Version 5.1
# ============================================================================
# MockEndpoint.ps1 - stand-in for RemoteHWInfo's http://localhost:60000/json.json
#
# Serves tests/fixtures/sensors.json on 127.0.0.1:<Port> and re-reads the
# scenario file on EVERY request, so a test can change the sensor values while
# the guard under test is running. Started and stopped by Run-Tests.ps1.
#
# Scenario file (JSON, all keys optional):
#   set    : [ { label, unit?, sensorIndex?, value } ]   change matching readings
#   remove : [ { label, unit?, sensorIndex? } ]          drop matching readings
#   add    : [ { label, sensorIndex?, unit?, value } ]   add a reading
#   igpu   : true                                        add an iGPU with a lower sensorIndex
#   delay  : seconds                                     answer slowly
#   down   : true                                        answer HTTP 503
# A value may be {"jitter":[base, range]} = base + random(0..range) per request.
#
# This file is pure ASCII (the degree sign is built from its char code).
# ============================================================================
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$ScenarioFile,
    [Parameter(Mandatory)][string]$FixtureFile
)

$ErrorActionPreference = "Stop"
$deg = [string][char]0x00B0

function Get-Value($v) {
    if ($v -is [psobject] -and $v.PSObject.Properties['jitter']) {
        return [math]::Round(([double]$v.jitter[0]) + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0 * ([double]$v.jitter[1]), 3)
    }
    return $v
}

function Test-ReadingMatch($r, $s) {
    if ($r.labelOriginal -ne $s.label) { return $false }
    if ($s.PSObject.Properties['unit'] -and $r.unit -ne $s.unit) { return $false }
    if ($s.PSObject.Properties['sensorIndex'] -and $r.sensorIndex -ne $s.sensorIndex) { return $false }
    return $true
}

function New-Response($sc) {
    $d = (Get-Content -Path $FixtureFile -Raw -Encoding UTF8) | ConvertFrom-Json
    $hw = $d.hwinfo
    $readings = New-Object System.Collections.ArrayList
    $sensors  = New-Object System.Collections.ArrayList
    foreach ($r in $hw.readings) { [void]$readings.Add($r) }
    foreach ($s in $hw.sensors)  { [void]$sensors.Add($s) }

    if ($sc.igpu) {
        $sensors.Insert(0, [pscustomobject]@{ entryIndex = 3; sensorId = 1; sensorInst = 0
            sensorNameOriginal = 'GPU [#1]: AMD Radeon(TM) Graphics'; sensorNameUser = 'GPU [#1]: AMD Radeon(TM) Graphics' })
        $readings.Insert(0, [pscustomobject]@{ entryIndex = 900; readingType = 1; sensorIndex = 3; readingId = 16777216
            labelOriginal = 'GPU Temperature'; labelUser = 'GPU Temperature'; unit = "${deg}C"; value = 41.0 })
    }
    foreach ($a in @($sc.add)) {
        if (-not $a) { continue }
        $idx  = if ($a.PSObject.Properties['sensorIndex']) { $a.sensorIndex } else { 6 }
        $unit = if ($a.PSObject.Properties['unit']) { $a.unit } else { "${deg}C" }
        [void]$readings.Add([pscustomobject]@{ entryIndex = 950 + $readings.Count; readingType = 1; sensorIndex = $idx
            readingId = 77000000; labelOriginal = $a.label; labelUser = $a.label; unit = $unit; value = (Get-Value $a.value) })
    }
    foreach ($s in @($sc.set)) {
        if (-not $s) { continue }
        foreach ($r in $readings) { if (Test-ReadingMatch $r $s) { $r.value = (Get-Value $s.value) } }
    }
    foreach ($s in @($sc.remove)) {
        if (-not $s) { continue }
        for ($i = $readings.Count - 1; $i -ge 0; $i--) { if (Test-ReadingMatch $readings[$i] $s) { $readings.RemoveAt($i) } }
    }

    $out = [pscustomobject]@{ hwinfo = [pscustomobject]@{
        signature = $hw.signature; version = $hw.version; revision = $hw.revision
        sensorCount = $sensors.Count; readingCount = $readings.Count
        sensors = @($sensors); readings = @($readings) } }
    return ($out | ConvertTo-Json -Depth 8 -Compress)
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        $first  = $reader.ReadLine()
        while ($true) { $h = $reader.ReadLine(); if ([string]::IsNullOrEmpty($h)) { break } }

        $sc = [pscustomobject]@{}
        try { $sc = (Get-Content -Path $ScenarioFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
        if ($null -eq $sc) { $sc = [pscustomobject]@{} }
        if ($sc.delay) { Start-Sleep -Seconds ([double]$sc.delay) }

        if ($first -notmatch '^GET /json\.json') {
            $head = "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($sc.down) {
            $head = "HTTP/1.1 503 Service Unavailable`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $body = [System.Text.Encoding]::UTF8.GetBytes((New-Response $sc))
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($hb, 0, $hb.Length)
            $stream.Write($body, 0, $body.Length)
        }
        $stream.Flush()
    } catch {
        # a client that gave up (timeout) must not stop the mock
    } finally {
        $client.Close()
    }
}
