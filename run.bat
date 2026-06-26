@echo off
REM ===========================================================================
REM  run.bat - task runner for the SSRS -> PBIRS migration toolkit (Windows).
REM
REM  This repo is a single PowerShell module:
REM    * RsMigration - the migration cmdlets, sequenced end-to-end by
REM      Invoke-RsMigration (native PowerShell; no child processes).
REM
REM  run.bat is the one-stop entry point on Windows: it runs the PowerShell
REM  quality gate and drives the migration runbook - loading parameters from a
REM  local ".env" file (copied from .env.example) so nothing lives on the
REM  command line. The encryption-key password is never stored: Invoke-RsMigration
REM  prompts for it as a SecureString when it is not supplied.
REM
REM  USAGE:  run.bat <command>
REM
REM  COMMANDS:
REM    test      PowerShell gate: Pester (>=90% coverage) + PSScriptAnalyzer.
REM    dry-run   Run the runbook read-only (inventory + validation, no writes).
REM    migrate   Run the FULL migration runbook (mutating - reads .env).
REM    clean     Delete coverage artifacts (coverage.xml / .coverage).
REM    help      Show this help (default when no command is given).
REM
REM  EXAMPLES:
REM    run.bat test
REM    run.bat dry-run
REM    run.bat migrate
REM ===========================================================================

setlocal enabledelayedexpansion

REM --- Resolve command -------------------------------------------------------
set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"

:dispatch
if /i "%CMD%"=="help"    ( call :help    & goto :end )
if /i "%CMD%"=="test"    ( call :test    & goto :finish )
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
echo Usage:  run.bat ^<command^>
echo.
echo   test      PowerShell gate: Pester ^>=90%% coverage + PSScriptAnalyzer.
echo   dry-run   Runbook read-only (inventory + validation, no writes).
echo   migrate   FULL migration runbook (mutating; reads .env).
echo   clean     Delete coverage artifacts.
echo   help      Show this help.
echo.
echo Configuration: copy .env.example to .env and fill it in. See README.md.
goto :eof

REM ===========================================================================
:test
echo [run] PowerShell gate: Pester + PSScriptAnalyzer ...
where pwsh >nul 2>nul || ( echo [run] ERROR: pwsh ^(PowerShell 7+^) not found on PATH. & exit /b 1 )
pwsh -NoProfile -File scripts\qg-ps.ps1 || exit /b 1
echo [run] PowerShell gate: PASS.
exit /b 0

REM ===========================================================================
:dry_run
call :load_env
set "DRYRUN=-DryRun"
echo [run] Running runbook in DRY-RUN mode (read-only) ...
call :invoke || exit /b 1
exit /b 0

REM ===========================================================================
:migrate
call :load_env
set "DRYRUN="
if defined RS_DRY_RUN call :resolve_dryrun
echo [run] Running migration runbook ...
call :invoke || exit /b 1
exit /b 0

:resolve_dryrun
if /i "%RS_DRY_RUN%"=="1"    set "DRYRUN=-DryRun"
if /i "%RS_DRY_RUN%"=="true" set "DRYRUN=-DryRun"
if /i "%RS_DRY_RUN%"=="yes"  set "DRYRUN=-DryRun"
if /i "%RS_DRY_RUN%"=="on"   set "DRYRUN=-DryRun"
exit /b 0

REM ===========================================================================
REM  Build and run the Invoke-RsMigration call from RS_* (.env) variables.
REM  Share ROOTS and FILE NAMES are passed as SEPARATE parameters - the module
REM  joins "<share> + <file>" itself, so no full backup/key path is built here.
REM  KeyPassword is NOT passed: Invoke-RsMigration prompts for it (SecureString).
REM ===========================================================================
:invoke
where pwsh >nul 2>nul || ( echo [run] ERROR: pwsh ^(PowerShell 7+^) not found on PATH. & exit /b 1 )
set "PSCMD=Import-Module '.\RsMigration\RsMigration.psd1';"
set "PSCMD=!PSCMD! Invoke-RsMigration"
set "PSCMD=!PSCMD! -SourceReportPortalUri '%RS_SOURCE_PORTAL_URI%'"
set "PSCMD=!PSCMD! -TargetReportPortalUri '%RS_TARGET_PORTAL_URI%'"
set "PSCMD=!PSCMD! -SourceSqlInstance '%RS_SOURCE_SQL_INSTANCE%'"
set "PSCMD=!PSCMD! -TargetSqlInstance '%RS_TARGET_SQL_INSTANCE%'"
set "PSCMD=!PSCMD! -DatabaseServerName '%RS_DATABASE_SERVER_NAME%'"
set "PSCMD=!PSCMD! -DatabaseName '%RS_DATABASE_NAME%'"
set "PSCMD=!PSCMD! -SourceSharePath '%RS_SOURCE_SHARE%'"
set "PSCMD=!PSCMD! -TargetSharePath '%RS_TARGET_SHARE%'"
set "PSCMD=!PSCMD! -KeyFile '%RS_KEY_FILE%'"
set "PSCMD=!PSCMD! -ReportServerBak '%RS_REPORTSERVER_BAK%'"
set "PSCMD=!PSCMD! -ReportServerTempDbBak '%RS_REPORTSERVERTEMPDB_BAK%'"
set "PSCMD=!PSCMD! -MachineName '%RS_STALE_MACHINE_NAME%'"
set "PSCMD=!PSCMD! -ActiveMachineName '%RS_ACTIVE_MACHINE_NAME%'"
set "PSCMD=!PSCMD! -ReportItem ('%RS_REPORTS%'.Split(',').Trim())"
set "PSCMD=!PSCMD! -DataSource ('%RS_DATA_SOURCES%'.Split(',').Trim())"
if defined RS_INCLUDE_SUBSCRIPTIONS set "PSCMD=!PSCMD! -IncludeSubscription ('%RS_INCLUDE_SUBSCRIPTIONS%'.Split(',').Trim())"
if defined DRYRUN set "PSCMD=!PSCMD! %DRYRUN%"
pwsh -NoProfile -Command "!PSCMD!" || exit /b 1
exit /b 0

REM ===========================================================================
:clean
echo [run] Cleaning coverage artifacts ...
if exist "coverage.xml" del /q "coverage.xml"
if exist ".coverage" del /q ".coverage"
echo [run] clean complete.
exit /b 0

REM ===========================================================================
REM  Helpers
REM ===========================================================================
:load_env
if not exist ".env" (
    echo [run] No .env found - relying on existing environment.
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
