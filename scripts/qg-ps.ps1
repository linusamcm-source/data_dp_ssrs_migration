#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell quality gate: Pester (with >=90% coverage) + PSScriptAnalyzer.
.DESCRIPTION
    Exits non-zero if any Pester test fails, if RsMigration code coverage is
    below 90%, or if PSScriptAnalyzer returns any Error/Warning diagnostics.
    Run from the worktree root: pwsh -NoProfile -File scripts/qg-ps.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # --- Pester + coverage -------------------------------------------------
    $config = New-PesterConfiguration
    $config.Run.Path = 'tests/pester'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = 'RsMigration/**/*.ps1'
    $config.CodeCoverage.CoveragePercentTarget = 90
    $config.Should.ErrorAction = 'Continue'

    $result = Invoke-Pester -Configuration $config

    $failed = $false

    if ($result.FailedCount -gt 0) {
        Write-Host "FAIL: $($result.FailedCount) Pester test(s) failed." -ForegroundColor Red
        $failed = $true
    }

    $coverage = $result.CodeCoverage
    if ($null -ne $coverage) {
        $commands = $coverage.CommandsAnalyzedCount
        $covered = $coverage.CommandsExecutedCount
        $percent = if ($commands -gt 0) { [math]::Round(($covered / $commands) * 100, 2) } else { 100 }
        Write-Host "Coverage: $percent% ($covered/$commands commands)" -ForegroundColor Cyan
        if ($percent -lt 90) {
            Write-Host "FAIL: coverage $percent% is below the 90% target." -ForegroundColor Red
            $failed = $true
        }
    }
    else {
        Write-Host 'FAIL: no coverage data produced.' -ForegroundColor Red
        $failed = $true
    }

    # --- PSScriptAnalyzer ---------------------------------------------------
    $analysis = foreach ($target in @('RsMigration', 'tests')) {
        Invoke-ScriptAnalyzer -Path $target -Recurse `
            -Settings 'PSScriptAnalyzerSettings.psd1' `
            -Severity @('Error', 'Warning')
    }

    if ($analysis) {
        Write-Host "FAIL: PSScriptAnalyzer returned $(@($analysis).Count) Error/Warning diagnostic(s):" -ForegroundColor Red
        $analysis | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-Host
        $failed = $true
    }
    else {
        Write-Host 'PSScriptAnalyzer: clean.' -ForegroundColor Green
    }

    if ($failed) {
        Write-Host 'qg-ps: FAILED' -ForegroundColor Red
        exit 1
    }

    Write-Host 'qg-ps: PASS' -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
