@echo off
REM ===========================================================================
REM  run.bat - task runner for the SSRS -> PBIRS migration toolkit (Windows).
REM
REM  This repo has two halves:
REM    * rs_migration  - Python orchestrator + REST client (the migration CLI).
REM    * RsMigration   - PowerShell module of wrapper cmdlets it spawns.
REM
REM  run.bat is the one-stop entry point on Windows: it bootstraps the Python
REM  virtualenv, runs both quality gates (Python + PowerShell), and drives the
REM  migration runbook itself - loading parameters from a local ".env" file
REM  (copied from .env.example) so secrets never live on the command line.
REM
REM  USAGE:  run.bat <command> [extra args...]
REM
REM  COMMANDS:
REM    setup       Create .venv + install package + dev tools via uv (pip fallback).
REM    test        Run BOTH quality gates (Python then PowerShell).
REM    test-py     Python gate: pytest with >=90% coverage, then ruff lint.
REM    test-ps     PowerShell gate: Pester (>=90% coverage) + PSScriptAnalyzer.
REM    lint        ruff lint only (no tests).
REM    dry-run     Run the runbook read-only (inventory + validation, no writes).
REM    migrate     Run the FULL migration runbook (mutating - reads .env).
REM    clean       Delete caches (.pytest_cache/.ruff_cache/__pycache__/coverage).
REM    help        Show this help (default when no command is given).
REM
REM  EXAMPLES:
REM    run.bat setup
REM    run.bat test
REM    run.bat dry-run
REM    run.bat migrate
REM    run.bat migrate --scheme http --report Q4Sales   (extra args override .env)
REM ===========================================================================

setlocal enabledelayedexpansion

set "VENV=.venv"
set "PY=%VENV%\Scripts\python.exe"
set "RUFF=%VENV%\Scripts\ruff.exe"
set "RSMIG=%VENV%\Scripts\rs-migration.exe"

REM --- Resolve command + collect any extra args (tokens 2..n) ----------------
set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"

set "EXTRA="
shift
:collect_args
if "%~1"=="" goto :dispatch
set "EXTRA=!EXTRA! %~1"
shift
goto :collect_args

:dispatch
if /i "%CMD%"=="help"    ( call :help    & goto :end )
if /i "%CMD%"=="setup"   ( call :setup   & goto :finish )
if /i "%CMD%"=="test"    ( call :test    & goto :finish )
if /i "%CMD%"=="test-py" ( call :test_py & goto :finish )
if /i "%CMD%"=="test-ps" ( call :test_ps & goto :finish )
if /i "%CMD%"=="lint"    ( call :lint    & goto :finish )
if /i "%CMD%"=="dry-run" ( call :dry_run & goto :finish )
if /i "%CMD%"=="migrate" ( call :migrate & goto :finish )
if /i "%CMD%"=="clean"   ( call :clean   & goto :finish )
echo [run] Unknown command: %CMD%
echo.
call :help
goto :end

:finish
if errorlevel 1 goto :fail
goto :end

REM ===========================================================================
:help
echo SSRS -^> PBIRS migration toolkit - run.bat
echo.
echo Usage:  run.bat ^<command^> [extra args...]
echo.
echo   setup     Create .venv + install package + dev tools (uv; pip fallback).
echo   test      Run BOTH quality gates (Python then PowerShell).
echo   test-py   Python gate: pytest ^>=90%% coverage + ruff.
echo   test-ps   PowerShell gate: Pester ^>=90%% coverage + PSScriptAnalyzer.
echo   lint      ruff lint only.
echo   dry-run   Runbook read-only (inventory + validation, no writes).
echo   migrate   FULL migration runbook (mutating; reads .env).
echo   clean     Delete caches and coverage artifacts.
echo   help      Show this help.
echo.
echo Configuration: copy .env.example to .env and fill it in. See README.md.
goto :eof

REM ===========================================================================
:setup
call :setup_impl || exit /b 1
echo [run] setup complete.
exit /b 0

:setup_impl
where uv >nul 2>nul && goto :setup_uv
echo [run] uv not found - falling back to python -m venv + pip.
if not exist "%PY%" (
    python -m venv %VENV% || exit /b 1
)
"%PY%" -m pip install -q --upgrade pip || exit /b 1
"%PY%" -m pip install -q -e ".[dev]" || exit /b 1
exit /b 0

:setup_uv
echo [run] Bootstrapping venv with uv in %VENV% ...
if not exist "%PY%" (
    uv venv %VENV% || exit /b 1
)
uv pip install -e ".[dev]" || exit /b 1
exit /b 0

REM ===========================================================================
:test
call :test_py || exit /b 1
call :test_ps || exit /b 1
echo [run] ALL gates passed.
exit /b 0

REM ===========================================================================
:test_py
call :ensure_venv || exit /b 1
echo [run] Python gate: pytest (coverage ^>=90%%) ...
"%PY%" -m pytest --cov=rs_migration --cov-report=term-missing --cov-fail-under=90 tests/python || exit /b 1
echo [run] Python gate: ruff ...
"%RUFF%" check rs_migration tests/python || exit /b 1
echo [run] Python gate: PASS.
exit /b 0

REM ===========================================================================
:test_ps
echo [run] PowerShell gate: Pester + PSScriptAnalyzer ...
where pwsh >nul 2>nul || ( echo [run] ERROR: pwsh ^(PowerShell 7+^) not found on PATH. & exit /b 1 )
pwsh -NoProfile -File scripts\qg-ps.ps1 || exit /b 1
echo [run] PowerShell gate: PASS.
exit /b 0

REM ===========================================================================
:lint
call :ensure_venv || exit /b 1
"%RUFF%" check rs_migration tests/python || exit /b 1
echo [run] lint: clean.
exit /b 0

REM ===========================================================================
:dry_run
call :ensure_venv || exit /b 1
call :load_env
echo [run] Running runbook in DRY-RUN mode (read-only) ...
"%RSMIG%" --dry-run!EXTRA! || exit /b 1
exit /b 0

REM ===========================================================================
:migrate
call :ensure_venv || exit /b 1
call :load_env
echo [run] Running FULL migration runbook ...
"%RSMIG%"!EXTRA! || exit /b 1
exit /b 0

REM ===========================================================================
:clean
echo [run] Cleaning caches ...
if exist ".pytest_cache" rd /s /q ".pytest_cache"
if exist ".ruff_cache" rd /s /q ".ruff_cache"
if exist "coverage.xml" del /q "coverage.xml"
if exist ".coverage" del /q ".coverage"
for /d /r %%d in (__pycache__) do @if exist "%%d" rd /s /q "%%d"
echo [run] clean complete.
exit /b 0

REM ===========================================================================
REM  Helpers
REM ===========================================================================
:ensure_venv
if not exist "%PY%" (
    echo [run] .venv missing - running setup first ...
    call :setup_impl || exit /b 1
)
exit /b 0

:load_env
if not exist ".env" (
    echo [run] No .env found - relying on existing environment / CLI flags.
    goto :eof
)
echo [run] Loading parameters from .env ...
for /f "usebackq eol=# tokens=1,* delims==" %%a in (".env") do (
    if not "%%a"=="" set "%%a=%%b"
)
goto :eof

REM ===========================================================================
:fail
echo [run] FAILED.
endlocal
exit /b 1

:end
endlocal
exit /b 0
