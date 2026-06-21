@echo off
:: ============================================================================
:: HWiNFO Thermal Guard — Complete Autostart
:: PS-based path detection + auto-download
:: Prefers PS7, falls back to PS5.1
:: Placement: shell:startup (place only the .vbs there!)
::
:: This script runs HIDDEN via the .vbs wrapper — all output below is
:: written to a logfile since console output is invisible in hidden mode.
:: ============================================================================
setlocal EnableDelayedExpansion

:: --- PATHS -------------------------------------------------------------------
set "THERMALGUARD_PS1=C:\Tools\HWiNFO-ThermalGuard\HWiNFO-ThermalGuard.ps1"
set "REMOTEHWINFO_URL=http://localhost:60000/json.json"
set "SCRIPT_DIR=%~dp0"
set "LOGDIR=%USERPROFILE%\HWiNFO-ThermalGuard"
set "LOGFILE=%LOGDIR%\autostart.log"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

:: Fresh log per run (thermalguard.log has the long-term history, this is per-run)
echo. > "%LOGFILE%"

call :log "=========================================================="
call :log "HWiNFO Thermal Guard - Autostart begin"
call :log "Script dir: %SCRIPT_DIR%"
call :log "=========================================================="

:: --- POWERSHELL AUTO-DETECT --------------------------------------------------
call :log "STEP 1: Detecting PowerShell..."
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
    :: Validate it is a real executable, not a near-empty alias stub
    for %%S in ("%PS_EXE%") do set "PS_EXE_SIZE=%%~zS"
    if !PS_EXE_SIZE! LSS 100000 (
        call :log "  - WARNING: %PS_EXE% is only !PS_EXE_SIZE! bytes - looks like a stub, not real pwsh.exe. Ignoring."
        set "PS_EXE="
    )
)

if defined PS_EXE (
    call :log "  - pwsh.exe (PowerShell 7) found at: %PS_EXE%"
) else (
    set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    call :log "  - pwsh.exe not found / invalid. Falling back to powershell.exe (5.1) at: %PS_EXE%"
)
call :log "  PS_EXE = %PS_EXE%"

if not exist "%PS_EXE%" (
    call :log "  FATAL: PS_EXE does not exist on disk: %PS_EXE%"
    goto :fatal
)

:: --- UNBLOCK FILES ------------------------------------------------------------
call :log "STEP 2: Unblocking files (removing Mark-of-the-Web)..."
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '%SCRIPT_DIR%' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }" >> "%LOGFILE%" 2>&1
call :log "  - Unblock-File pass complete (errorlevel %ERRORLEVEL%)"

:: --- SHARED MEMORY -------------------------------------------------------------
call :log "STEP 3: Enabling HWiNFO Shared Memory (Registry)..."
reg add "HKCU\SOFTWARE\HWiNFO64\Settings" /v SensorsSM /t REG_DWORD /d 1 /f >> "%LOGFILE%" 2>&1
call :log "  - reg add errorlevel: %ERRORLEVEL%"

:: --- RESOLVE PATHS --------------------------------------------------------------
call :log "STEP 4: Resolving paths (PS1 -Resolve : scan + auto-download)..."
call :log "  Calling: %PS_EXE% -File ""%THERMALGUARD_PS1%"" -Resolve"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%THERMALGUARD_PS1%" -Resolve >> "%LOGFILE%" 2>&1
set "RESOLVE_ERR=%ERRORLEVEL%"
call :log "  - -Resolve call finished with errorlevel %RESOLVE_ERR%"

set "PATHFILE=%TEMP%\thermalguard_paths.txt"
if not exist "%PATHFILE%" (
    call :log "  ERROR: %PATHFILE% does not exist! -Resolve did not write it."
    call :log "  Check %THERMALGUARD_PS1% manually: & '%THERMALGUARD_PS1%' -Resolve"
    goto :fatal
)
call :log "  - Path file found: %PATHFILE%"
call :log "  -- contents --"
type "%PATHFILE%" >> "%LOGFILE%" 2>&1
call :log "  -- end contents --"

for /f "tokens=1,* delims==" %%A in (%PATHFILE%) do (
    if "%%A"=="HWINFO_EXE" set "HWINFO_EXE=%%B"
    if "%%A"=="REMOTEHWINFO_EXE" set "REMOTEHWINFO_EXE=%%B"
    if "%%A"=="FIPHA_EXE" set "FIPHA_EXE=%%B"
)

call :log "  Parsed HWINFO_EXE       = [%HWINFO_EXE%]"
call :log "  Parsed REMOTEHWINFO_EXE = [%REMOTEHWINFO_EXE%]"
call :log "  Parsed FIPHA_EXE        = [%FIPHA_EXE%]"

call :log "STEP 4b: Unblocking resolved executables (Mark-of-the-Web removal)..."
if not "%HWINFO_EXE%"=="" if exist "%HWINFO_EXE%" (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%HWINFO_EXE%' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
    call :log "  - Unblocked: %HWINFO_EXE%"
)
if not "%REMOTEHWINFO_EXE%"=="" if exist "%REMOTEHWINFO_EXE%" (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%REMOTEHWINFO_EXE%' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
    call :log "  - Unblocked: %REMOTEHWINFO_EXE%"
)
if not "%FIPHA_EXE%"=="" if exist "%FIPHA_EXE%" (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%FIPHA_EXE%' -ErrorAction SilentlyContinue" >> "%LOGFILE%" 2>&1
    call :log "  - Unblocked: %FIPHA_EXE%"
)
:: Also unblock the entire folder each resolved exe lives in, in case of DLL dependencies
if not "%HWINFO_EXE%"=="" (
    for %%F in ("%HWINFO_EXE%") do "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '%%~dpF' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }" >> "%LOGFILE%" 2>&1
)
if not "%REMOTEHWINFO_EXE%"=="" (
    for %%F in ("%REMOTEHWINFO_EXE%") do "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '%%~dpF' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }" >> "%LOGFILE%" 2>&1
)
if not "%FIPHA_EXE%"=="" (
    for %%F in ("%FIPHA_EXE%") do "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath '%%~dpF' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }" >> "%LOGFILE%" 2>&1
)
call :log "  - Folder-level unblock pass complete."

if "%HWINFO_EXE%"=="" (
    call :log "  FATAL: HWiNFO64 not found and download failed."
    goto :fatal
)
if "%REMOTEHWINFO_EXE%"=="" (
    call :log "  FATAL: RemoteHWInfo not found and download failed."
    goto :fatal
)

if not exist "%HWINFO_EXE%" (
    call :log "  FATAL: HWINFO_EXE path does not exist on disk: %HWINFO_EXE%"
    goto :fatal
)
for %%S in ("%HWINFO_EXE%") do set "HWINFO_SIZE=%%~zS"
call :log "  HWINFO_EXE size: !HWINFO_SIZE! bytes"
if !HWINFO_SIZE! LSS 50000 (
    call :log "  FATAL: HWINFO_EXE looks like a stub/shortcut, not the real exe (!HWINFO_SIZE! bytes)."
    goto :fatal
)

if not exist "%REMOTEHWINFO_EXE%" (
    call :log "  FATAL: REMOTEHWINFO_EXE path does not exist on disk: %REMOTEHWINFO_EXE%"
    goto :fatal
)
for %%S in ("%REMOTEHWINFO_EXE%") do set "REMOTE_SIZE=%%~zS"
call :log "  REMOTEHWINFO_EXE size: !REMOTE_SIZE! bytes"
if !REMOTE_SIZE! LSS 5000 (
    call :log "  FATAL: REMOTEHWINFO_EXE looks like a stub/shortcut, not the real exe (!REMOTE_SIZE! bytes)."
    goto :fatal
)

if not "%FIPHA_EXE%"=="" (
    if exist "%FIPHA_EXE%" (
        for %%S in ("%FIPHA_EXE%") do set "FIPHA_SIZE=%%~zS"
        call :log "  FIPHA_EXE size: !FIPHA_SIZE! bytes"
        if !FIPHA_SIZE! LSS 5000 (
            call :log "  WARNING: FIPHA_EXE looks like a stub (!FIPHA_SIZE! bytes). Disabling fipha for this run."
            set "FIPHA_EXE="
        )
    ) else (
        call :log "  WARNING: FIPHA_EXE path does not exist on disk: %FIPHA_EXE% - disabling fipha for this run."
        set "FIPHA_EXE="
    )
)

:: ============================================================================
:: STEP 5: HWiNFO64
:: ============================================================================
call :log "STEP 5: HWiNFO64..."
tasklist /FI "IMAGENAME eq HWiNFO64.exe" 2>NUL | find /I "HWiNFO64.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    call :log "  - Already running. Skipping start."
    goto :hwinfo_ready
)

call :log "  - Not running. Starting: %HWINFO_EXE%"
start "" "%HWINFO_EXE%"
call :log "  - start command issued. Polling for process (max 60s)..."

set /A retries=0
:wait_hwinfo
timeout /t 3 /nobreak >nul
tasklist /FI "IMAGENAME eq HWiNFO64.exe" 2>NUL | find /I "HWiNFO64.exe" >NUL
if %ERRORLEVEL% EQU 0 goto :hwinfo_found
set /A retries+=1
call :log "  - still not seen, retry %retries%/20"
if %retries% GEQ 20 (
    call :log "  FATAL: HWiNFO64 did not appear within 60s."
    goto :fatal
)
goto :wait_hwinfo

:hwinfo_found
call :log "  - HWiNFO64 process detected. Waiting 15s for sensor init..."
timeout /t 15 /nobreak >nul

:hwinfo_ready
call :log "  - HWiNFO64 ready."

:: ============================================================================
:: STEP 6: RemoteHWInfo
:: ============================================================================
call :log "STEP 6: RemoteHWInfo..."
tasklist /FI "IMAGENAME eq RemoteHWInfo.exe" 2>NUL | find /I "RemoteHWInfo.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    call :log "  - Already running. Skipping start, going straight to HTTP check."
    goto :check_remote_http
)

call :log "  - Not running. Starting: %REMOTEHWINFO_EXE%"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%REMOTEHWINFO_EXE%' -ArgumentList '-hwinfo=1 -gpuz=0 -afterburner=0' -WindowStyle Hidden" >> "%LOGFILE%" 2>&1
call :log "  - Start-Process call issued (errorlevel %ERRORLEVEL%)"

:check_remote_http
call :log "  - Checking HTTP endpoint: %REMOTEHWINFO_URL%"
set /A http_retries=0
:wait_remote_http
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-RestMethod -Uri '%REMOTEHWINFO_URL%' -TimeoutSec 3; if ($null -ne $r.hwinfo -and $null -ne $r.hwinfo.readings) { Write-Output ('OK - ' + $r.hwinfo.readingCount + ' readings') ; exit 0 } else { Write-Output 'BAD JSON'; exit 1 } } catch { Write-Output ('FAIL: ' + $_.Exception.Message); exit 1 }" >> "%LOGFILE%" 2>&1
if %ERRORLEVEL% EQU 0 goto :remote_ready
set /A http_retries+=1
call :log "  - not ready yet, retry %http_retries%/6"
if %http_retries% GEQ 6 (
    call :log "  FATAL: RemoteHWInfo HTTP endpoint never became ready."
    goto :fatal
)
timeout /t 3 /nobreak >nul
goto :wait_remote_http

:remote_ready
call :log "  - RemoteHWInfo HTTP endpoint ready."

:: ============================================================================
:: STEP 7: ThermalGuard
:: ============================================================================
call :log "STEP 7: ThermalGuard..."
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    call :log "  - Already running. Skipping."
    goto :step8
)

call :log "  - Not running. Starting via %PS_EXE%..."
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%PS_EXE%' -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%THERMALGUARD_PS1%\"' -WindowStyle Hidden" >> "%LOGFILE%" 2>&1
call :log "  - Start-Process call issued (errorlevel %ERRORLEVEL%). Waiting 3s to verify..."
timeout /t 3 /nobreak >nul

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    call :log "  - ThermalGuard confirmed running."
) else (
    call :log "  FATAL: ThermalGuard could not be confirmed running after start attempt!"
    call :log "  Check thermalguard.log in %LOGDIR% for crash details."
    goto :fatal
)

:: ============================================================================
:: STEP 8: fipha (HWiNFO - MQTT - Home Assistant)
:: ============================================================================
:step8
call :log "STEP 8: fipha..."
if "%FIPHA_EXE%"=="" (
    call :log "  - Not configured / not found (toggle: $EnableFipha in PS1). Skipping."
    goto :done
)

tasklist /FI "IMAGENAME eq fipha.exe" 2>NUL | find /I "fipha.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    call :log "  - Already running. Skipping."
    goto :done
)

call :log "  - Not running. Starting: %FIPHA_EXE%"
for %%F in ("%FIPHA_EXE%") do set "FIPHA_DIR=%%~dpF"
call :log "  - Working directory: %FIPHA_DIR%"
start "" /d "%FIPHA_DIR%" "%FIPHA_EXE%"
call :log "  - start command issued. Polling for process (max 15s)..."

set /A fipha_retries=0
:wait_fipha
timeout /t 3 /nobreak >nul
tasklist /FI "IMAGENAME eq fipha.exe" 2>NUL | find /I "fipha.exe" >NUL
if %ERRORLEVEL% EQU 0 goto :fipha_ready
set /A fipha_retries+=1
call :log "  - still not seen, retry %fipha_retries%/5"
if %fipha_retries% GEQ 5 (
    call :log "  WARNING: fipha not visible after 15s. It may have exited immediately"
    call :log "           (missing config, MQTT broker unreachable, etc). Continuing anyway."
    goto :done
)
goto :wait_fipha

:fipha_ready
call :log "  - fipha running and connecting to MQTT."

:: ============================================================================
:: DONE
:: ============================================================================
:done
call :log "=========================================================="
call :log "All steps complete. Summary:"
call :log "  PowerShell     = %PS_EXE%"
call :log "  HWiNFO64       = %HWINFO_EXE%"
call :log "  RemoteHWInfo   = %REMOTEHWINFO_EXE%"
call :log "  ThermalGuard   = %THERMALGUARD_PS1%"
call :log "  fipha          = %FIPHA_EXE%"
call :log "=========================================================="
goto :eof

:fatal
call :log "=========================================================="
call :log "AUTOSTART FAILED - see steps above for the exact point of failure"
call :log "=========================================================="
exit /b 1

:: ============================================================================
:: :log subroutine - writes timestamped line to both console and logfile
:: ============================================================================
:log
echo [%date% %time%] %~1
echo [%date% %time%] %~1 >> "%LOGFILE%"
exit /b 0
