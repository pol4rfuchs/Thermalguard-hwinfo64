@echo off
:: ============================================================================
:: HWiNFO Thermal Guard — Complete Autostart
:: PS-based path detection + auto-download
:: Prefers PS7, falls back to PS5.1
:: Placement: shell:startup (place only the .vbs there!)
:: ============================================================================
setlocal EnableDelayedExpansion

:: --- THERMALGUARD SCRIPT PATH -----------------------------------------------
:: Adjust this path if the script is located elsewhere
set "THERMALGUARD_PS1=C:\Tools\HWiNFO-ThermalGuard\HWiNFO-ThermalGuard.ps1"
set "REMOTEHWINFO_URL=http://localhost:60000/json.json"

:: --- POWERSHELL AUTO-DETECT -------------------------------------------------
where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PS_EXE=pwsh.exe"
    echo [%time%] PowerShell 7 (pwsh) detected.
) else (
    set "PS_EXE=powershell.exe"
    echo [%time%] PowerShell 5.1 detected.
)

:: --- ENABLE SHARED MEMORY ---------------------------------------------------
echo [%time%] Enabling HWiNFO Shared Memory (Registry)...
reg add "HKCU\SOFTWARE\HWiNFO64\Settings" /v SensorsSM /t REG_DWORD /d 1 /f >nul 2>&1

:: --- RESOLVE PATHS (Scan + Download via PS) ---------------------------------
echo [%time%] Resolving paths (scan + auto-download)...
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%THERMALGUARD_PS1%" -Resolve

set "PATHFILE=%TEMP%\thermalguard_paths.txt"
if not exist "%PATHFILE%" (
    echo [%time%] ERROR: Path resolution failed. Check %THERMALGUARD_PS1%
    exit /b 1
)

:: Read paths from temp file
for /f "tokens=1,* delims==" %%A in (%PATHFILE%) do (
    if "%%A"=="HWINFO_EXE" set "HWINFO_EXE=%%B"
    if "%%A"=="REMOTEHWINFO_EXE" set "REMOTEHWINFO_EXE=%%B"
    if "%%A"=="FIPHA_EXE" set "FIPHA_EXE=%%B"
)

echo [%time%] HWiNFO64:     %HWINFO_EXE%
echo [%time%] RemoteHWInfo: %REMOTEHWINFO_EXE%
echo [%time%] fipha:        %FIPHA_EXE%

if "%HWINFO_EXE%"=="" (
    echo [%time%] ERROR: HWiNFO64 not found and download failed.
    exit /b 1
)
if "%REMOTEHWINFO_EXE%"=="" (
    echo [%time%] ERROR: RemoteHWInfo not found and download failed.
    exit /b 1
)

:: ============================================================================
:: 1. HWiNFO64
:: ============================================================================
tasklist /FI "IMAGENAME eq HWiNFO64.exe" 2>NUL | find /I "HWiNFO64.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    echo [%time%] HWiNFO64 already running. Skipping.
    goto :hwinfo_ready
)

echo [%time%] Starting HWiNFO64...
start "" "%HWINFO_EXE%"

set /A retries=0
:wait_hwinfo
timeout /t 3 /nobreak >nul
tasklist /FI "IMAGENAME eq HWiNFO64.exe" 2>NUL | find /I "HWiNFO64.exe" >NUL
if %ERRORLEVEL% EQU 0 goto :hwinfo_found
set /A retries+=1
if %retries% GEQ 20 (
    echo [%time%] ERROR: HWiNFO64 did not start within 60s.
    exit /b 1
)
echo [%time%] Waiting for HWiNFO64... (%retries%/20)
goto :wait_hwinfo

:hwinfo_found
echo [%time%] HWiNFO64 found. Waiting 15s for sensor initialization...
timeout /t 15 /nobreak >nul

:hwinfo_ready
echo [%time%] HWiNFO64 ready.

:: ============================================================================
:: 2. RemoteHWInfo
:: ============================================================================
tasklist /FI "IMAGENAME eq RemoteHWInfo.exe" 2>NUL | find /I "RemoteHWInfo.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    echo [%time%] RemoteHWInfo already running. Skipping start.
    goto :check_remote_http
)

echo [%time%] Starting RemoteHWInfo...
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%REMOTEHWINFO_EXE%' -ArgumentList '-hwinfo=1 -gpuz=0 -afterburner=0' -WindowStyle Hidden"

:check_remote_http
set /A http_retries=0
:wait_remote_http
echo [%time%] Checking RemoteHWInfo HTTP endpoint...
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-RestMethod -Uri '%REMOTEHWINFO_URL%' -TimeoutSec 3; if ($null -ne $r.hwinfo -and $null -ne $r.hwinfo.readings) { exit 0 } else { exit 1 } } catch { exit 1 }"
if %ERRORLEVEL% EQU 0 goto :remote_ready
set /A http_retries+=1
if %http_retries% GEQ 6 (
    echo [%time%] ERROR: RemoteHWInfo HTTP not ready.
    exit /b 1
)
echo [%time%] RemoteHWInfo not ready yet... (%http_retries%/6)
timeout /t 3 /nobreak >nul
goto :wait_remote_http

:remote_ready
echo [%time%] RemoteHWInfo ready.

:: ============================================================================
:: 3. ThermalGuard
:: ============================================================================
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    echo [%time%] ThermalGuard already running. Skipping.
    goto :done
)

echo [%time%] Starting ThermalGuard via %PS_EXE%...
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "Start-Process %PS_EXE% -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%THERMALGUARD_PS1%""' -WindowStyle Hidden"

timeout /t 3 /nobreak >nul
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "if (Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -match '(?i)-File\s+.*HWiNFO-ThermalGuard\.ps1' }) { exit 0 } else { exit 1 }"
if %ERRORLEVEL% EQU 0 (
    echo [%time%] ThermalGuard started.
) else (
    echo [%time%] ERROR: ThermalGuard could not be started!
    exit /b 1
)

:: ============================================================================
:: 4. fipha  (HWiNFO -> MQTT -> Home Assistant)
:: ============================================================================
if "%FIPHA_EXE%"=="" (
    echo [%time%] fipha not found (toggle in PS1: $EnableFipha). Skipping.
    goto :done
)

tasklist /FI "IMAGENAME eq fipha.exe" 2>NUL | find /I "fipha.exe" >NUL
if %ERRORLEVEL% EQU 0 (
    echo [%time%] fipha already running. Skipping.
    goto :done
)

echo [%time%] Starting fipha (HWiNFO Shared Memory -> MQTT)...
for %%F in ("%FIPHA_EXE%") do set "FIPHA_DIR=%%~dpF"
start "" /d "%FIPHA_DIR%" "%FIPHA_EXE%"

set /A fipha_retries=0
:wait_fipha
timeout /t 3 /nobreak >nul
tasklist /FI "IMAGENAME eq fipha.exe" 2>NUL | find /I "fipha.exe" >NUL
if %ERRORLEVEL% EQU 0 goto :fipha_ready
set /A fipha_retries+=1
if %fipha_retries% GEQ 5 (
    echo [%time%] WARNING: fipha not visible after 15s.
    goto :done
)
echo [%time%] Waiting for fipha... (%fipha_retries%/5)
goto :wait_fipha

:fipha_ready
echo [%time%] fipha started and connecting to MQTT.

:done
echo.
echo [%time%] === All services active ===
echo            PowerShell     = %PS_EXE%
echo            HWiNFO64       = %HWINFO_EXE%
echo            RemoteHWInfo   = %REMOTEHWINFO_EXE%
echo            ThermalGuard   = %THERMALGUARD_PS1%
echo            fipha          = %FIPHA_EXE%
echo.
timeout /t 5 /nobreak >nul
endlocal
