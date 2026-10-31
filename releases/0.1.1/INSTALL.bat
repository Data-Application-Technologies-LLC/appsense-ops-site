@echo off
setlocal enabledelayedexpansion
rem appsense-ops client installer — run from the extracted release folder.
rem Requires: Python 3.11+ (py launcher), and config.yaml filled in next to this file.

set "ROOT=%~dp0"
set "VENV=%ROOT%.venv"

where py >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Python launcher "py" not found. Install Python 3.11+ from python.org.
    exit /b 1
)

set "PYEXE="
for /f "tokens=*" %%i in ('py -3.11 -c "import sys; print(sys.executable)" 2^>nul') do set "PYEXE=%%i"
if not defined PYEXE for /f "tokens=*" %%i in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do set "PYEXE=%%i"
if not defined PYEXE (
    echo [ERROR] Python 3 not found via py launcher.
    exit /b 1
)
echo Using Python: %PYEXE%

echo Creating venv at "%VENV%" ...
"%PYEXE%" -m venv "%VENV%" || exit /b 1

echo Installing appsense-ops wheel ...
"%VENV%\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check --upgrade pip || exit /b 1
"%VENV%\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check "%ROOT%appsense_ops-*.whl" || (
    echo [ERROR] Wheel install failed.
    exit /b 1
)

if not exist "%ROOT%config.yaml" (
    echo.
    echo [NEXT] No config.yaml found. Copy config.client-template.yaml to config.yaml
    echo        and fill in profile, opaque_id, and the Hermes vault login, then re-run
    echo        this script or run the selfcheck:
    echo          "%VENV%\Scripts\appsense-ops.exe" --selfcheck
) else (
    echo.
    echo Running selfcheck ...
    "%VENV%\Scripts\appsense-ops.exe" --selfcheck
)

echo.
echo Done. MCP registration snippet is in DEPLOY.md section 5.
endlocal
