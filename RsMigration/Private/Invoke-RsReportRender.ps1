function Invoke-RsReportRender {
    <#
    .SYNOPSIS
        Thin seam over the live REST report-render call so callers stay mockable.
    .DESCRIPTION
        Render-testing a report requires a live PBIRS REST endpoint, which does
        not exist on the macOS/Linux quality gate, so the real render cannot run
        there. Routing the render through this wrapper lets tests Mock
        Invoke-RsReportRender instead and simulate a render failure by throwing.
        The render obtains its REST session from New-RsMigrationRestSession
        (current Windows identity) and threads that exact session into
        Out-RsRestCatalogItem via -WebSession; both statements are exercised
        under mocks in tests.
    #>
    [CmdletBinding()]
    param([string]$RsItem, [string]$ReportPortalUri)
    $session = New-RsMigrationRestSession -ReportPortalUri $ReportPortalUri
    Out-RsRestCatalogItem -RsItem $RsItem -ReportPortalUri $ReportPortalUri -Destination $env:TEMP -Overwrite -WebSession $session
}
