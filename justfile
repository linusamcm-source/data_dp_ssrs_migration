opus:
    @claude --dangerously-skip-permissions "/caveman"

# PowerShell quality gate: Pester (>=90% coverage) + PSScriptAnalyzer.
qg-ps:
    pwsh -NoProfile -File scripts/qg-ps.ps1