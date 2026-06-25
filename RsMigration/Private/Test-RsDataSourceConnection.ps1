function Test-RsDataSourceConnection {
    <#
    .SYNOPSIS
        Thin seam over the live data-source connectivity probe so callers stay
        mockable (Windows-only-command mockability seam).
    .DESCRIPTION
        The real connectivity check (Test-RsRestItemDataSource) requires a live
        PBIRS target and cannot run on the macOS/Linux quality gate, so it cannot
        be exercised there. Routing the probe through this wrapper lets tests Mock
        Test-RsDataSourceConnection instead. The single statement below is the only
        code here - it cannot execute on the gate and therefore stays uncovered, so
        it is kept to one line.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$DataSource, [string]$ReportPortalUri)
    [bool](Test-RsRestItemDataSource -RsItem $DataSource -ReportPortalUri $ReportPortalUri)
}
