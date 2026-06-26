function Test-RsDataSourceConnection {
    <#
    .SYNOPSIS
        Thin seam over the live data-source connectivity probe so callers stay
        mockable (Windows-only-command mockability seam).
    .DESCRIPTION
        The real connectivity check (Test-RsRestItemDataSource) requires a live
        PBIRS target and cannot run on the macOS/Linux quality gate, so it cannot
        be exercised there. Routing the probe through this wrapper lets tests Mock
        Test-RsDataSourceConnection instead. The probe obtains its REST session
        from New-RsMigrationRestSession (current Windows identity) and threads
        that exact session into Test-RsRestItemDataSource via -WebSession; both
        statements are exercised under mocks in tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$DataSource, [string]$ReportPortalUri)
    $session = New-RsMigrationRestSession -ReportPortalUri $ReportPortalUri
    [bool](Test-RsRestItemDataSource -RsItem $DataSource -ReportPortalUri $ReportPortalUri -WebSession $session)
}
