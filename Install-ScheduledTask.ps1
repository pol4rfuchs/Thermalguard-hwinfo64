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

# Permission check (always, read-only): the task runs this folder's scripts and
# the HWiNFO64 / RemoteHWInfo / fipha programs with administrator rights. If a
# standard user (or any non-elevated program of yours) can overwrite those files
# it can replace them and gain administrator rights. The check lists such
# folders. -FixPermissions restricts them to administrators (Administrators and
# SYSTEM full control, Users read/execute only, owner = Administrators) after
# showing the folders and asking for confirmation (-Yes skips the question).
# The HWiNFO64 folder is only reported, never changed: HWiNFO may need to write
# its settings there. A folder under Program Files is already protected.
#
# Note: after -FixPermissions, editing the ThermalGuard scripts needs an
# elevated editor / prompt.

param(
    [int]$RepeatMinutes = 5,
    [switch]$FixPermissions,
    [switch]$Yes
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

# --- Time-based repetition trigger (the one that really drives the self-heal) ----
# A repetition attached to the logon trigger only starts counting at the next
# logon, so a task registered in a running session did not repeat at all (seen
# in practice: the guard was killed and nothing restarted it). A plain
# time trigger starts repeating right away, shows a NextRunTime, and keeps
# repeating after reboots. The duration is an explicit 10 years (finite and valid
# on every Windows version). Both triggers run the same launcher; "do not start
# a new instance" plus the launcher's silent fast path make overlaps harmless.
$Triggers = @($Trigger)
if ($RepeatMinutes -gt 0) {
    try {
        $RepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        $Triggers += $RepeatTrigger
    } catch {
        Write-Host "WARNING: could not create the time-based repetition trigger ($($_.Exception.Message))." -ForegroundColor Yellow
    }
}

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers -Principal $Principal -Settings $Settings | Out-Null

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
    $nextRun = $null
    try { $nextRun = (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).NextRunTime } catch { }
    if ($interval -and $nextRun -and $nextRun.Year -gt 2000) {
        Write-Host "Self-heal: the launcher is re-run every $interval (ISO 8601) and exits silently while the guard is running." -ForegroundColor Green
        Write-Host "           Next scheduled run: $nextRun" -ForegroundColor Green
    } elseif ($interval) {
        Write-Host "Self-heal: repetition $interval is stored, but Task Scheduler shows NO next run time yet." -ForegroundColor Yellow
        Write-Host "           It may only start after the next logon. Test: kill the guard and see whether it comes back within $RepeatMinutes minutes." -ForegroundColor Yellow
    } else {
        Write-Host "WARNING: no repetition is stored on the task. A crashed guard will NOT be restarted until the next logon." -ForegroundColor Yellow
        Write-Host "         Check Task Scheduler -> '$TaskName' -> Triggers -> Edit -> 'Repeat task every'." -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "Test it now without logging off: " -NoNewline
Write-Host "Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
Write-Host ""

# --- Permission check / fix ------------------------------------------------------
function Get-WritableByStandardUsers {
    # Same logic as in HWiNFO-ThermalGuard.ps1 (the two files are deployed separately).
    # Returns "<account>: <rights>" / "owned by <account>" when $Path can be modified
    # or re-permissioned by a non-administrator account, otherwise $null.
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }

    $adminClass = @('S-1-5-32-544', 'S-1-5-18', 'S-1-3-0', 'S-1-3-1')
    $unsafe = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')) { [void]$unsafe.Add($s) }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    [void]$unsafe.Add($me.User.Value)
    foreach ($g in $me.Groups) {
        $v = $g.Value
        if ($adminClass -contains $v -or $v -like 'S-1-5-80-*') { continue }
        [void]$unsafe.Add($v)
    }

    $fsr  = [System.Security.AccessControl.FileSystemRights]
    $mask = $fsr::WriteData -bor $fsr::AppendData -bor $fsr::Delete -bor $fsr::DeleteSubdirectoriesAndFiles -bor $fsr::ChangePermissions -bor $fsr::TakeOwnership

    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $null }

    try {
        $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($unsafe.Contains($ownerSid) -and $adminClass -notcontains $ownerSid) {
            return "owned by $($acl.Owner) (an owner can always rewrite the permissions)"
        }
    } catch { }

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if (($rule.FileSystemRights -band $mask) -eq 0) { continue }
        try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($unsafe.Contains($sid)) { return "$($rule.IdentityReference): $($rule.FileSystemRights)" }
    }
    return $null
}

function Protect-Folder {
    # Administrators + SYSTEM full control, Users read/execute, no inherited entries,
    # owner = Administrators. Uses well-known SIDs, so it is language independent.
    param([string]$Path)

    # This script runs with $ErrorActionPreference = "Stop". In Windows PowerShell 5.1 that
    # turns ANY stderr line of a native command captured with 2>&1 (icacls prints
    # "Access denied" when the owner cannot be changed) into a terminating error and would
    # abort this function half way. Local to this function only.
    $ErrorActionPreference = 'Continue'

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 3) { throw "Refusing to change the permissions of a drive root: $Path" }
    if ($env:SystemRoot -and $full.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to change the permissions of a folder inside the Windows directory: $Path"
    }

    # 1) The folder itself: no inheritance and ONLY these three entries. Every other
    #    explicit entry (e.g. the current user's own) is removed, which "icacls /grant:r"
    #    does not do.
    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $sidUsers  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $inherit   = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $noProp    = [System.Security.AccessControl.PropagationFlags]::None
    $aclOk = $true
    try {
        $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem, 'FullControl',      $inherit, $noProp, 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins, 'FullControl',      $inherit, $noProp, 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidUsers,  'ReadAndExecute',   $inherit, $noProp, 'Allow')))
        Set-Acl -LiteralPath $full -AclObject $acl -ErrorAction Stop
    } catch { $aclOk = $false }

    # 2) Everything below inherits from the folder. Do NOT use
    #    "icacls <folder> /inheritance:r /grant:r ... /T" for this: it leaves every FILE
    #    with an EMPTY permission list, i.e. nobody (not even an administrator) can read
    #    or start it any more.
    $null = & icacls.exe "$full\*" /reset /T /C 2>&1

    # 3) Owner = Administrators. Only works from an elevated prompt, and only after step
    #    2: the files must already grant Administrators full control.
    $null = & icacls.exe $full /setowner '*S-1-5-32-544' /T /C 2>&1

    # icacls reports success (exit code 0) even when a non-elevated prompt could not
    # change the owner, so read the result back instead of trusting exit codes.
    $ownerOk = $false
    try { $ownerOk = ((Get-Acl -LiteralPath $full -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') } catch { }
    $emptyAcl = @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue |
                  Where-Object { @((Get-Acl -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Access).Count -eq 0 })
    return [pscustomobject]@{ Path = $full; PermissionsSet = ($aclOk -and $emptyAcl.Count -eq 0); OwnerSet = $ownerOk; FilesWithEmptyAcl = $emptyAcl.Count }
}

try {
    Write-Host "--- Permission check (this task runs these folders with administrator rights) ---" -ForegroundColor Cyan
    $toolsDir = "C:\Tools"
    $targets  = New-Object System.Collections.ArrayList
    [void]$targets.Add([pscustomobject]@{ Path = $ScriptDir; Fix = $true; What = "ThermalGuard scripts" })
    if (Test-Path -LiteralPath $toolsDir) {
        foreach ($spec in @(@('RemoteHWInfo.exe', $true), @('fipha.exe', $true), @('HWiNFO64.exe', $false))) {
            Get-ChildItem -LiteralPath $toolsDir -Filter $spec[0] -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\WindowsApps\\' } |
                ForEach-Object { [void]$targets.Add([pscustomobject]@{ Path = $_.DirectoryName; Fix = $spec[1]; What = $_.Name }) }
        }
    }

    $exposed = New-Object System.Collections.ArrayList
    foreach ($t in ($targets | Sort-Object Path -Unique)) {
        $why = Get-WritableByStandardUsers -Path $t.Path
        if ($why) {
            [void]$exposed.Add($t)
            Write-Host "  [EXPOSED] $($t.Path)  ($($t.What)): $why" -ForegroundColor Yellow
        } else {
            Write-Host "  [ok]      $($t.Path)  ($($t.What))" -ForegroundColor Green
        }
    }

    if ($exposed.Count -eq 0) {
        Write-Host "No folder can be modified by standard users." -ForegroundColor Green
    }
    elseif (-not $FixPermissions) {
        Write-Host ""
        Write-Host "A non-elevated program could replace files in the folders above and gain administrator rights." -ForegroundColor Yellow
        Write-Host "To restrict them to administrators, run this script again with -FixPermissions." -ForegroundColor Yellow
    }
    else {
        $fixable = @($exposed | Where-Object { $_.Fix })
        $manual  = @($exposed | Where-Object { -not $_.Fix })
        foreach ($m in $manual) {
            Write-Host "  Not changed automatically: $($m.Path) ($($m.What)). Restrict it by hand if HWiNFO does not need to write there." -ForegroundColor Yellow
        }
        if ($fixable.Count -gt 0) {
            Write-Host ""
            Write-Host "-FixPermissions will set these folders (and everything below them) to:" -ForegroundColor Cyan
            Write-Host "  Administrators + SYSTEM: full control | Users: read and execute | owner: Administrators | no inherited entries"
            foreach ($f in $fixable) { Write-Host "  $($f.Path)" }
            $go = $Yes
            if (-not $go) {
                $answer = Read-Host "Apply now? [y/N]"
                $go = ($answer -match '^(?i)y(es)?$')
            }
            if (-not $go) {
                Write-Host "Cancelled. Nothing was changed." -ForegroundColor Yellow
            } else {
                foreach ($f in $fixable) {
                    $r = Protect-Folder -Path $f.Path
                    if ($r.PermissionsSet -and $r.OwnerSet) { Write-Host "  [done]  $($r.Path)" -ForegroundColor Green }
                    else { Write-Host "  [PARTIAL] $($r.Path): permissions set = $($r.PermissionsSet), owner set = $($r.OwnerSet) (the owner change needs an elevated prompt)" -ForegroundColor Yellow }
                    if ($r.FilesWithEmptyAcl -gt 0) {
                        Write-Host "  [ERROR]   $($r.FilesWithEmptyAcl) file(s) in $($r.Path) have an EMPTY permission list and cannot be read or started. Repair: icacls `"$($r.Path)\*`" /reset /T /C" -ForegroundColor Red
                    }
                    $left = Get-WritableByStandardUsers -Path $f.Path
                    if ($left) { Write-Host "            still exposed: $left" -ForegroundColor Yellow }
                }
            }
        }
    }
} catch {
    Write-Host "Permission check failed (the task itself is registered): $($_.Exception.Message)" -ForegroundColor Yellow
}
