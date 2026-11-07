#requires -Version 5.1
# ============================================================================
# Find-NewGames.ps1
#
# Finds newly installed games and offers them for the Stage-2 kill list.
#
# How it works:
#   1. SCAN (default, no admin needed): looks into the install folders of
#      Steam, GOG, Rockstar, Epic, Ubisoft, EA and Battle.net, picks the game
#      executables and writes NEW ones to a waiting list
#        %USERPROFILE%\HWiNFO-ThermalGuard\DetectedGames.json
#      The kill list of the guard is NOT touched by the scan.
#   2. APPROVE (-Approve, ELEVATED PowerShell): asks per game
#        y = add to ApprovedGames.txt   n = ask again later   i = never ask again
#        a = add this and all remaining   q = stop here, keep the rest waiting
#      ApprovedGames.txt lives NEXT TO the guard script (the folder that
#      Install-ScheduledTask.ps1 -FixPermissions protects), so a normal program
#      cannot add process names to the kill list. The guard reads the file at
#      every Stage 2, in addition to $KillProcesses.
#
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1              # scan
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -Approve     # confirm (admin)
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -List        # show state
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -Remove Name # take one out (admin)
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -InstallTask # run the scan automatically
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -Reset       # clear the waiting list (then scan again)
#   powershell -ExecutionPolicy Bypass -File .\Find-NewGames.ps1 -AddPath "F:\Gaming Librarys"
#       remember a folder that holds one sub-folder per launcher/library (e.g.
#       F:\Gaming Librarys\Battle.net\<game>, ...\SteamLibrary\steamapps\common\<game>,
#       ...\Ubisoft Game Launcher\games\<game>). It is scanned on every run.
#
# -NtfyUrl https://ntfy.sh/topic  sends a message when new candidates are found.
# -Yes  (with -Approve) approves everything without asking - use with care.
#
# Heuristic: per game folder the two largest .exe files (after removing
# installers, crash handlers, anti-cheat and launcher helpers) are candidates.
# That can include a wrong file, which is why nothing is added without your
# confirmation. Names of protected system processes and browsers can never be
# added. This script is pure ASCII for the same reason as the guard.
# ============================================================================

param(
    [switch]$Approve,
    [switch]$List,
    [switch]$Yes,
    [string[]]$Remove = @(),
    [switch]$InstallTask,
    [switch]$Reset,
    [string[]]$AddPath = @(),
    [string]$NtfyUrl = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuardScript  = Join-Path $ScriptDir "HWiNFO-ThermalGuard.ps1"
$ApprovedFile = Join-Path $ScriptDir "ApprovedGames.txt"
$StateDir     = Join-Path $env:USERPROFILE "HWiNFO-ThermalGuard"
$PendingFile  = Join-Path $StateDir "DetectedGames.json"
$IgnoredFile  = Join-Path $StateDir "IgnoredGames.txt"
$PathsFile    = Join-Path $StateDir "ScanPaths.txt"

# Names that must never end up in the kill list (system, shell, security tools,
# browsers/launchers that are not games). Compared case-insensitively.
$ProtectedNames = @(
    "System", "Idle", "Registry", "smss", "csrss", "wininit", "winlogon", "services",
    "lsass", "svchost", "explorer", "dwm", "fontdrvhost", "sihost", "taskhostw",
    "ctfmon", "conhost", "powershell", "pwsh", "cmd", "wscript", "cscript",
    "MsMpEng", "NisSrv", "SecurityHealthService", "HWiNFO64", "HWiNFO32",
    "remotehwinfo", "fipha", "Steam", "steamwebhelper", "EpicGamesLauncher",
    "GalaxyClient", "Battle.net", "Agent", "Origin", "EADesktop", "EABackgroundService",
    "UbisoftConnect", "upc", "RockstarService", "Launcher", "LauncherPatcher",
    "chrome", "firefox", "msedge",
    "Game", "Benchmark", "testapp", "Client", "Server", "Main", "App", "Test", "Demo"
)

# File names that are never the game itself (regex on the file name).
$ExcludeFileRegex = '^(unins\d*|uninst\w*|setup\w*|install\w*|vc_?redist\S*|vcredist\S*|dxsetup|dxwebsetup|dotnet\S*|ndp\S*|oalinst|physx\S*|UnityCrashHandler\d*|crashpad\S*|crashreport\S*|crashsender\S*|bugreport\S*|BEService\S*|BEClient\S*|EasyAntiCheat\S*|EACLauncher|EOSBootstrapper|UplayWebCore|UbisoftGameLauncher\S*|upc|cleanup\S*|touchup|dwebp|7z\S*|ActivationUI|QuickSFV|redist\S*|DXSETUP|handler|launcherpatcher|CefSharp\S*|CrashHandler\S*|\S*crash_?reporter\S*|\S*installer\S*|\S*uninstall\S*|\S*editor\S*|worldbuilder\S*|converttogeo\S*|\S*launcher\S*|\S*server\S*|\S*benchmark\S*|\S*_BE|\S*diag\S*|3dmark\S*|dashboardx|utilities|logmate)\.exe$'

# Folder names that are never searched (regex on the folder name).
$ExcludeDirRegex = '^(_?CommonRedist|redist\S*|__Installer|DirectX|DotNet\S*|vcredist\S*|EasyAntiCheat\S*|BattlEye|Support|Tools|ThirdParty|Engine|Prerequisites|\.egstore|Launcher|Social Club|Steamworks Shared|SteamLinuxRuntime\S*|Proton\S*|Steam Controller Configs)$'

# Game folders that are tools, not games (regex on the folder name, anywhere in it).
$ExcludeGameRegex = 'Benchmark|3DMark|Dedicated Server|\bSDK\b|Dashboard|Soundtrack|Wallpaper'

function Write-Info([string]$Text) { Write-Host $Text }

function Test-ValidProcessName([string]$Name) {
    return ($Name -match '^[A-Za-z0-9_][A-Za-z0-9_\-\. ]{0,63}$')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- read/write helpers ---------------------------------------------------------
function Get-NameList([string]$Path) {
    $out = @()
    if (Test-Path $Path) {
        foreach ($line in (Get-Content -Path $Path -ErrorAction SilentlyContinue)) {
            $n = ($line -replace '#.*$', '').Trim()
            if ($n -and (Test-ValidProcessName $n)) { $out += $n }
        }
    }
    return @($out)
}

function Get-PendingList {
    if (-not (Test-Path $PendingFile)) { return @() }
    try {
        $raw = Get-Content -Path $PendingFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch {
        Write-Info "WARNING: $PendingFile unreadable ($($_.Exception.Message)) - starting with an empty waiting list."
        return @()
    }
}

function Save-PendingList($Items) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $arr = @($Items)
    if ($arr.Count -eq 0) { Set-Content -Path $PendingFile -Value "[]" -Encoding UTF8; return }
    $json = ConvertTo-Json -InputObject $arr -Depth 4
    Set-Content -Path $PendingFile -Value $json -Encoding UTF8
}

# Process names that are already in the guard's own $KillProcesses block.
function Get-GuardKillNames {
    $names = @()
    if (Test-Path $GuardScript) {
        $txt = [System.IO.File]::ReadAllText($GuardScript)
        $m = [regex]::Match($txt, '(?s)\$KillProcesses\s*=\s*@\((.*?)\r?\n\)')
        if ($m.Success) {
            foreach ($q in [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')) { $names += $q.Groups[1].Value }
        }
    }
    return @($names)
}

# --- find install folders per launcher -----------------------------------------
# Returns objects { Launcher; Path; IsRoot }. IsRoot = the folder CONTAINS game
# folders; otherwise the folder IS one game folder.
function Add-Source($List, [string]$Launcher, [string]$Path, [bool]$IsRoot) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $p = $Path.Trim().Trim('"').TrimEnd('\')
    if ($p -and (Test-Path -LiteralPath $p -PathType Container)) {
        $List.Add([pscustomobject]@{ Launcher = $Launcher; Path = $p; IsRoot = $IsRoot }) | Out-Null
    }
}

function Get-RegValue([string]$Key, [string]$Name) {
    try {
        $item = Get-ItemProperty -LiteralPath $Key -ErrorAction Stop
        return [string]$item.$Name
    } catch { return "" }
}

# Folders added with -AddPath: one sub-folder per launcher/library, games below it.
function Get-ExtraPaths {
    $out = @()
    if (Test-Path -LiteralPath $PathsFile) {
        foreach ($line in (Get-Content -LiteralPath $PathsFile -ErrorAction SilentlyContinue)) {
            $l = $line.Trim()
            if ($l -and -not $l.StartsWith('#')) { $out += $l }
        }
    }
    return $out
}

function Get-GameSources {
    $src = New-Object System.Collections.ArrayList

    # Steam: main folder plus every library from libraryfolders.vdf
    $steamRoots = @()
    foreach ($k in @(@("HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"), @("HKCU:\Software\Valve\Steam", "SteamPath"))) {
        $v = Get-RegValue $k[0] $k[1]
        if ($v) { $steamRoots += $v }
    }
    foreach ($sr in @($steamRoots | Select-Object -Unique)) {
        $sr = $sr -replace '/', '\'
        Add-Source $src "Steam" (Join-Path $sr "steamapps\common") $true
        $vdf = Join-Path $sr "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $lib = ($matches[1] -replace '\\\\', '\')
                    Add-Source $src "Steam" (Join-Path $lib "steamapps\common") $true
                }
            }
        }
    }

    # Epic: one manifest per installed game
    $manifestDir = Join-Path $env:ProgramData "Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path -LiteralPath $manifestDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $manifestDir -Filter *.item -ErrorAction SilentlyContinue)) {
            try {
                $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                Add-Source $src "Epic" ([string]$j.InstallLocation) $false
            } catch { }
        }
    }

    # GOG: registry entry per game
    foreach ($key in (Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games" -ErrorAction SilentlyContinue)) {
        Add-Source $src "GOG" (Get-RegValue $key.PSPath "path") $false
    }

    # Rockstar
    foreach ($key in (Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Rockstar Games" -ErrorAction SilentlyContinue)) {
        Add-Source $src "Rockstar" (Get-RegValue $key.PSPath "InstallFolder") $false
    }

    # Ubisoft
    foreach ($key in (Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs" -ErrorAction SilentlyContinue)) {
        Add-Source $src "Ubisoft" (Get-RegValue $key.PSPath "InstallDir") $false
    }

    # EA / Origin
    foreach ($base in @("HKLM:\SOFTWARE\WOW6432Node\EA Games", "HKLM:\SOFTWARE\EA Games")) {
        foreach ($key in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            Add-Source $src "EA" (Get-RegValue $key.PSPath "Install Dir") $false
        }
    }

    # Battle.net: the Blizzard games register as normal uninstall entries
    foreach ($base in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")) {
        foreach ($key in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $pub = Get-RegValue $key.PSPath "Publisher"
            if ($pub -eq "Blizzard Entertainment") {
                $dn = Get-RegValue $key.PSPath "DisplayName"
                if ($dn -notmatch 'Battle\.net') { Add-Source $src "Battle.net" (Get-RegValue $key.PSPath "InstallLocation") $false }
            }
        }
    }

    # Default folders, on every fixed drive (covers games the registry does not list)
    $drives = @()
    try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object { $_.DeviceID }) } catch { $drives = @("C:") }
    foreach ($d in $drives) {
        Add-Source $src "Steam"    "$d\SteamLibrary\steamapps\common" $true
        Add-Source $src "Epic"     "$d\Epic Games" $true
        Add-Source $src "GOG"      "$d\GOG Games" $true
        Add-Source $src "GOG"      "$d\Program Files (x86)\GOG Galaxy\Games" $true
        Add-Source $src "Rockstar" "$d\Program Files\Rockstar Games" $true
        Add-Source $src "Ubisoft"  "$d\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games" $true
        Add-Source $src "EA"       "$d\Program Files\EA Games" $true
        Add-Source $src "EA"       "$d\Program Files (x86)\Origin Games" $true
        Add-Source $src "EA"       "$d\Program Files\Electronic Arts" $true
    }

    # User-defined library folders (-AddPath)
    foreach ($ep in @(Get-ExtraPaths)) {
        if (-not (Test-Path -LiteralPath $ep -PathType Container)) { continue }
        foreach ($lib in (Get-ChildItem -LiteralPath $ep -Directory -ErrorAction SilentlyContinue)) {
            $root = $lib.FullName
            foreach ($sub in @("steamapps\common", "games")) {
                $cand = Join-Path $lib.FullName $sub
                if (Test-Path -LiteralPath $cand -PathType Container) { $root = $cand; break }
            }
            Add-Source $src $lib.Name $root $true
        }
    }

    # expand roots to game folders and de-duplicate by path (first source wins)
    $games = @{}
    foreach ($s in $src) {
        if ($s.IsRoot) {
            foreach ($sub in (Get-ChildItem -LiteralPath $s.Path -Directory -ErrorAction SilentlyContinue)) {
                if ($sub.Name -notmatch $ExcludeDirRegex -and $sub.Name -notmatch $ExcludeGameRegex) { $k = $sub.FullName.ToLowerInvariant(); if (-not $games.ContainsKey($k)) { $games[$k] = [pscustomobject]@{ Launcher = $s.Launcher; Path = $sub.FullName } } }
            }
        } else {
            $leaf = Split-Path -Leaf $s.Path
            if ($leaf -notmatch $ExcludeDirRegex -and $leaf -notmatch $ExcludeGameRegex) { $k = $s.Path.ToLowerInvariant(); if (-not $games.ContainsKey($k)) { $games[$k] = [pscustomobject]@{ Launcher = $s.Launcher; Path = $s.Path } } }
        }
    }
    return @($games.Values)
}

# The two largest candidate executables of one game folder.
function Get-GameExecutables([string]$GamePath) {
    $found = @()
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($GamePath, 0))
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $dir = $cur[0]; $depth = $cur[1]
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Filter *.exe -ErrorAction SilentlyContinue)) {
            if ($f.Name -match $ExcludeFileRegex) { continue }
            if ($f.Length -lt 100KB) { continue }
            $found += $f
        }
        if ($depth -lt 4) {
            foreach ($sd in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
                if ($sd.Name -match $ExcludeDirRegex) { continue }
                $stack.Push(@($sd.FullName, ($depth + 1)))
            }
        }
    }
    $sorted = @($found | Sort-Object Length -Descending)
    if ($sorted.Count -eq 0) { return @() }
    # Unreal games: the "-Shipping" file is the real game, the small stub next to it is not needed.
    $ship = @($sorted | Where-Object { $_.BaseName -match '-Shipping$' })
    if ($ship.Count -gt 0) { return @($ship | Select-Object -First 1) }
    # Otherwise the largest file, plus a second one only if it is of similar size (e.g. DX / Vulkan variants).
    $top = $sorted[0]
    return @($sorted | Where-Object { $_.Length -ge ($top.Length * 0.25) } | Select-Object -First 2)
}

function Send-Ntfy([string]$Text) {
    if (-not $NtfyUrl) { return }
    try { Invoke-RestMethod -Uri $NtfyUrl -Method Post -Body $Text -TimeoutSec 10 | Out-Null }
    catch { Write-Info "ntfy failed: $($_.Exception.Message)" }
}

# --- modes ----------------------------------------------------------------------
function Invoke-Scan {
    $known = @()
    $known += Get-NameList $ApprovedFile
    $known += Get-NameList $IgnoredFile
    $known += Get-GuardKillNames
    $known += $ProtectedNames
    $knownSet = @{}
    foreach ($k in $known) { $knownSet[$k.ToLowerInvariant()] = $true }

    $pending = @(Get-PendingList)
    $pendingSet = @{}
    foreach ($p in $pending) { $pendingSet[([string]$p.process).ToLowerInvariant()] = $true }

    $newOnes = @()
    $games = @(Get-GameSources)
    Write-Info "Scanned $($games.Count) game folder(s)."
    foreach ($g in $games) {
        foreach ($exe in (Get-GameExecutables $g.Path)) {
            $proc = [System.IO.Path]::GetFileNameWithoutExtension($exe.Name)
            if (-not (Test-ValidProcessName $proc)) { continue }
            $key = $proc.ToLowerInvariant()
            if ($knownSet.ContainsKey($key) -or $pendingSet.ContainsKey($key)) { continue }
            $pendingSet[$key] = $true
            $newOnes += [pscustomobject]@{
                process  = $proc
                game     = (Split-Path -Leaf $g.Path)
                launcher = $g.Launcher
                path     = $exe.FullName
                found    = (Get-Date).ToString("yyyy-MM-dd HH:mm")
            }
        }
    }

    if ($newOnes.Count -gt 0) {
        Save-PendingList (@($pending) + @($newOnes))
        Write-Info "$($newOnes.Count) new candidate(s):"
        foreach ($n in $newOnes) { Write-Info ("  {0,-32} {1} ({2})" -f $n.process, $n.game, $n.launcher) }
        Write-Info "Confirm with: Find-NewGames.ps1 -Approve   (elevated PowerShell)"
        Send-Ntfy ("ThermalGuard: {0} new game process(es) detected ({1}). Confirm with Find-NewGames.ps1 -Approve." -f $newOnes.Count, (($newOnes | ForEach-Object { $_.process }) -join ", "))
    } else {
        Write-Info "No new games found. Waiting for confirmation: $($pending.Count)."
    }
}

function Invoke-ApproveFlow {
    if (-not (Test-IsAdmin)) {
        Write-Info "ERROR: -Approve needs an ELEVATED PowerShell (ApprovedGames.txt sits next to the guard script, which can be locked down to administrators)."
        exit 1
    }
    $pending = @(Get-PendingList)
    if ($pending.Count -eq 0) { Write-Info "Nothing waiting for confirmation. Run a scan first."; return }

    $keep = @()
    $approvedNow = @()
    $ignoredNow = @()
    $takeAll = $false
    $stop = $false
    foreach ($p in $pending) {
        $name = [string]$p.process
        if (-not (Test-ValidProcessName $name) -or ($ProtectedNames -contains $name)) { continue }
        if ($stop) { $keep += $p; continue }
        Write-Info ""
        Write-Info ("{0}   ({1}, {2})" -f $name, $p.game, $p.launcher)
        Write-Info ("  {0}" -f $p.path)
        if ($Yes -or $takeAll) { $ans = "y" } else { $ans = (Read-Host "  Add to kill list? [y]es / [n]ot now / [i]gnore forever / [a]ll remaining yes / [q]uit").Trim().ToLowerInvariant() }
        switch -Regex ($ans) {
            '^(y|j)'  { $approvedNow += $p }
            '^a'      { $takeAll = $true; $approvedNow += $p }
            '^q'      { $stop = $true; $keep += $p }
            '^i'      { $ignoredNow += $p }
            default   { $keep += $p }
        }
    }

    if ($approvedNow.Count -gt 0) {
        $lines = @()
        if (-not (Test-Path $ApprovedFile)) {
            $lines += "# Process names added to the Stage-2 kill list by Find-NewGames.ps1 (one per line)."
        }
        foreach ($a in $approvedNow) { $lines += ("{0}   # {1}, {2}, {3}" -f $a.process, $a.game, $a.launcher, (Get-Date).ToString("yyyy-MM-dd")) }
        Add-Content -Path $ApprovedFile -Value $lines -Encoding UTF8
        Write-Info ""
        Write-Info "Added $($approvedNow.Count) to $ApprovedFile"
    }
    if ($ignoredNow.Count -gt 0) {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -Path $IgnoredFile -Value @($ignoredNow | ForEach-Object { $_.process }) -Encoding UTF8
        Write-Info "Ignoring $($ignoredNow.Count) from now on ($IgnoredFile)"
    }
    Save-PendingList $keep
    Write-Info "Still waiting: $($keep.Count). The guard picks up the file at the next Stage 2, no restart needed."
}

function Invoke-RemoveFlow {
    if (-not (Test-IsAdmin)) { Write-Info "ERROR: -Remove needs an ELEVATED PowerShell."; exit 1 }
    if (-not (Test-Path $ApprovedFile)) { Write-Info "No ApprovedGames.txt - nothing to remove."; return }
    $lines = @(Get-Content -Path $ApprovedFile)
    $out = @()
    $removed = 0
    foreach ($line in $lines) {
        $n = ($line -replace '#.*$', '').Trim()
        if ($n -and ($Remove | Where-Object { $_ -ieq $n })) { $removed++; continue }
        $out += $line
    }
    Set-Content -Path $ApprovedFile -Value $out -Encoding UTF8
    Write-Info "Removed $removed entr$(if ($removed -eq 1) {'y'} else {'ies'})."
}

function Invoke-AddPathFlow {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $have = @(Get-ExtraPaths)
    foreach ($p in $AddPath) {
        $full = $p.Trim().Trim('"').TrimEnd('\')
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { Write-Info "Not a folder, skipped: $full"; continue }
        if ($have | Where-Object { $_ -ieq $full }) { Write-Info "Already saved: $full"; continue }
        Add-Content -Path $PathsFile -Value $full -Encoding UTF8
        Write-Info "Saved: $full  (scanned on every run; list: $PathsFile)"
    }
}

function Invoke-ResetFlow {
    Save-PendingList @()
    Write-Info "Waiting list cleared ($PendingFile). Run the scan again to rebuild it."
}

function Show-State {
    Write-Info "Approved (kill list extension, $ApprovedFile):"
    $a = @(Get-NameList $ApprovedFile)
    if ($a.Count -eq 0) { Write-Info "  (none)" } else { foreach ($n in $a) { Write-Info "  $n" } }
    Write-Info ""
    Write-Info "Extra library folders ($PathsFile):"
    $xp = @(Get-ExtraPaths)
    if ($xp.Count -eq 0) { Write-Info "  (none)" } else { foreach ($n in $xp) { Write-Info "  $n" } }
    Write-Info ""
    Write-Info "Waiting for confirmation ($PendingFile):"
    $p = @(Get-PendingList)
    if ($p.Count -eq 0) { Write-Info "  (none)" } else { foreach ($i in $p) { Write-Info ("  {0,-32} {1} ({2})" -f $i.process, $i.game, $i.launcher) } }
    Write-Info ""
    Write-Info "Ignored ($IgnoredFile):"
    $ig = @(Get-NameList $IgnoredFile)
    if ($ig.Count -eq 0) { Write-Info "  (none)" } else { foreach ($n in $ig) { Write-Info "  $n" } }
}

function Install-ScanTask {
    $taskName = "HWiNFO Thermal Guard - Game scan"
    $self = Join-Path $ScriptDir "Find-NewGames.ps1"
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
    if ($NtfyUrl) { $arg += " -NtfyUrl `"$NtfyUrl`"" }
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($t1, $t2) -Settings $settings -Principal $principal -Force | Out-Null
    Write-Info "Task '$taskName' registered: scan at logon and every 6 hours (normal user rights, only writes the waiting list)."
}

# --- main -----------------------------------------------------------------------
if ($List)              { Show-State; exit 0 }
if ($Remove.Count -gt 0){ Invoke-RemoveFlow; exit 0 }
if ($InstallTask)       { Install-ScanTask; exit 0 }
if ($Reset)             { Invoke-ResetFlow; exit 0 }
if ($AddPath.Count -gt 0) { Invoke-AddPathFlow; exit 0 }
if ($Approve)           { Invoke-ApproveFlow; exit 0 }
Invoke-Scan
