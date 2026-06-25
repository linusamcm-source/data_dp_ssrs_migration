function Invoke-RsReportRender {
    <#
    .SYNOPSIS
        Thin seam over the live REST report-render call so callers stay mockable.
    .DESCRIPTION
        Render-testing a report requires a live PBIRS REST endpoint, which does
        not exist on the macOS/Linux quality gate, so the real render cannot run
        there. Routing the render through this wrapper lets tests Mock
        Invoke-RsReportRender instead and simulate a render failure by throwing.
        The single statement below is the only code here - it cannot execute on
        the gate and therefore stays uncovered, so it is kept to one line.
    #>
    [CmdletBinding()]
    param([string]$RsItem, [string]$ReportPortalUri)
    Out-RsRestCatalogItem -RsItem $RsItem -ReportPortalUri $ReportPortalUri -Destination $env:TEMP -Force
}
