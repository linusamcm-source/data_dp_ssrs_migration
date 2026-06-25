Set-StrictMode -Version Latest

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath = Join-Path $PSScriptRoot 'Public'

# Dot-source Private helpers first (Public functions depend on them), then Public.
foreach ($scope in @($privatePath, $publicPath)) {
    if (Test-Path $scope) {
        Get-ChildItem -Path $scope -Filter '*.ps1' -File | ForEach-Object {
            . $_.FullName
        }
    }
}

# Auto-export: every Public/<Verb>-Noun.ps1 basename becomes an exported function,
# so dropping a new Public script needs no manifest edit.
$publicFunctions = @()
if (Test-Path $publicPath) {
    $publicFunctions = @(Get-ChildItem -Path $publicPath -Filter '*.ps1' -File |
            Select-Object -ExpandProperty BaseName)
}

# Always call Export-ModuleMember so that Private helpers never leak when there
# are zero Public scripts (an empty list exports nothing).
Export-ModuleMember -Function $publicFunctions
