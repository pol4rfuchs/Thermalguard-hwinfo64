@echo off
:: ============================================================================
:: HWiNFO Thermal Guard - Autostart Launcher v2.0
::
:: ARCHITECTURE CHANGE: this file no longer starts or checks HWiNFO64,
:: RemoteHWInfo or fipha itself. HWiNFO-ThermalGuard.ps1 is now the single
:: supervisor for all three of those processes (its own Test-Requirements
:: function and Watchdog loop handle them). This file's only job is to:
::   1) find a working PowerShell engine
::   2) unblock the known script files (Mark-of-the-Web removal)
::   3) launch HWiNFO-ThermalGuard.ps1
::
:: PATH RULE: this file assumes HWiNFO-ThermalGuard.ps1 lives in the SAME
:: folder as this .bat file (resolved via %~dp0, not a hardcoded path).
:: The matching Start-HWiNFO-Remote.vbs must also live in that same folder.
:: All three files (.bat, .vbs, .ps1) belong together in one folder, e.g.
:: C:\Tools\HWiNFO-ThermalGuard\ - there is no other supported layout.
:: ============================================================================
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "THERMALGUARD_PS1=%SCRIPT_DIR%HWiNFO-ThermalGuard.ps1"
set "LOGDIR=%USERPROFILE%\HWiNFO-ThermalGuard"
set "LOGFILE=%LOGDIR%\autostart.log"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
echo. > "%LOGFILE%"

call :log "=========================================================="
call :log "HWiNFO Thermal Guard - Autostart begin (launcher v2.0)"
call :log "Script dir: %SCRIPT_DIR%"
call :log "=========================================================="

:: --- STEP 1: existence check before doing anything else (report finding #4) -
call :log "STEP 1: Checking for HWiNFO-ThermalGuard.ps1..."
if not exist "%THERMALGUARD_PS1%" (
    call :log "FATAL: %THERMALGUARD_PS1% does not exist."
    call :log "Make sure HWiNFO-ThermalGuard.ps1 is in the same folder as this .bat file."
    goto :fatal
)
call :log "  - Found: %THERMALGUARD_PS1%"

:: --- STEP 2: PowerShell engine detection -------------------------------------
call :log "STEP 2: Detecting PowerShell..."
set "PS_EXE="
for /f "delims=" %%P in ('where pwsh 2^>nul') do (
    if not defined PS_EXE (
        echo %%P | findstr /I /C:"\WindowsApps\" >nul
        if errorlevel 1 (
            set "PS_EXE=%%P"
        ) else (
            call :log "  - Skipping WindowsApps alias stub: %%P"
        )
    )
)
if defined PS_EXE (
    for %%S in ("%PS_EXE%") do set "PS_EXE_SIZE=%%~zS"
    if !PS_EXE_SIZE! LSS 100000 (
        call :log "  - WARNING: %PS_EXE% is only !PS_EXE_SIZE! bytes, looks like a stub. Ignoring."
        set "PS_EXE="
    )
)
if defined PS_EXE (
    call :log "  - Using PowerShell 7: %PS_EXE%"
) else (
    set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    call :log "  - PowerShell 7 not found/invalid. Using PowerShell 5.1: %PS_EXE%"
)
if not exist "%PS_EXE%" (
    call :log "FATAL: PS_EXE does not exist on disk: %PS_EXE%"
    goto :fatal
)

:: --- STEP 3: unblock ONLY the known script files, no recursive folder scan --
:: Report finding #20: blanket recursive unblocking of entire directories
:: is a security risk (it would strip Mark-of-the-Web from unrelated files
:: too). Only these three specific, known files are touched.
call :log "STEP 3: Unblocking known script files..."
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%THERMALGUARD_PS1%' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%SCRIPT_DIR%Start-HWiNFO-Remote.bat' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%SCRIPT_DIR%Start-HWiNFO-Remote.vbs' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
call :log "  - Unblock pass complete."

:: --- STEP 4: launch ThermalGuard.ps1 (sole supervisor) ----------------------
:: HWiNFO64, RemoteHWInfo and fipha are started and supervised entirely by
:: the PS1 itself (Test-Requirements + Watchdog). This .bat does not touch
:: them, eliminating the duplicate-orchestration and fipha race-condition
:: issues that existed when both files managed the same processes.
call :log "STEP 4: ThermalGuard..."
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    call :log "  - Already running. Skipping."
    goto :done
)

call :log "  - Not running. Starting via %PS_EXE%..."
start "" /min "%PS_EXE%" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%THERMALGUARD_PS1%"
call :log "  - start command issued (errorlevel %ERRORLEVEL%). Waiting 5s to verify..."
timeout /t 5 /nobreak >nul

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    call :log "  - ThermalGuard confirmed running."
) else (
    call :log "FATAL: ThermalGuard could not be confirmed running after start attempt."
    call :log "Check thermalguard.log in %LOGDIR% for crash details."
    goto :fatal
)

:done
call :log "=========================================================="
call :log "Launcher complete. ThermalGuard.ps1 now owns HWiNFO64,"
call :log "RemoteHWInfo and fipha supervision from here on."
call :log "=========================================================="
goto :eof

:fatal
call :log "=========================================================="
call :log "AUTOSTART FAILED - see steps above for the exact point of failure"
call :log "=========================================================="
exit /b 1

:log
echo [%date% %time%] %~1
echo [%date% %time%] %~1 >> "%LOGFILE%"
exit /b 0
