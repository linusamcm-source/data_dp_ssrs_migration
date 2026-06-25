function Invoke-RsMigrationValidation {
    <#
    .SYNOPSIS
        Post-migration validation: render-tests reports, probes data-source
        connectivity, and confirms auto-recreated msdb SQL Agent subscription
        jobs, returning an aggregate pass/fail report (impl-doc 6 Phase C / C12-C14).
    .DESCRIPTION
        Runs the three post-migration checks from impl-doc Phase C against the
        target PBIRS instance and its catalog database:

          C12. Render-test every report item over REST and record pass/fail per
               item. The render call is routed through the internal
               Invoke-RsReportRender seam so it is mockable on non-Windows test
               hosts; a render that throws is recorded as a failure for that item.
          C12. Probe each data source's connectivity via the internal
               Test-RsDataSourceConnection seam (also mockable) and record the
               result per data source.
          C13. Query msdb for the auto-recreated SQL Agent subscription jobs via
               Invoke-DbaQuery and record whether any are present.

        The returned object's Success property is $false if ANY individual check
        failed (a report that did not render, a data source that did not connect,
        or no subscription jobs present) and $true only when every check passed.
    .PARAMETER ReportItem
        Catalog paths of the report items to render-test.
    .PARAMETER DataSource
        Catalog paths of the data sources to probe for connectivity.
    .PARAMETER SqlInstance
        Target SQL Server instance hosting msdb (for the subscription-job check).
    .PARAMETER Database
        Database to query for SQL Agent subscription jobs (msdb).
    .PARAMETER ReportPortalUri
        Base PBIRS report-portal URI used for the REST render and connectivity probes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ReportItem,

        [Parameter(Mandatory)]
        [string[]]$DataSource,

        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [string]$Database = 'msdb',

        [Parameter(Mandatory)]
        [string]$ReportPortalUri
    )

    # C12 - render-test each report item, recording pass/fail per item.
    $reportResults = foreach ($item in $ReportItem) {
        $rendered = $true
        try {
            Invoke-RsReportRender -RsItem $item -ReportPortalUri $ReportPortalUri
        }
        catch {
            $rendered = $false
        }
        [pscustomobject]@{ RsItem = $item; Success = $rendered }
    }

    # C12 - probe each data source's connectivity, recording the result per source.
    $dataSourceResults = foreach ($ds in $DataSource) {
        $connected = [bool](Test-RsDataSourceConnection -DataSource $ds -ReportPortalUri $ReportPortalUri)
        [pscustomobject]@{ DataSource = $ds; Connected = $connected }
    }

    # C13 - confirm auto-recreated SQL Agent subscription jobs exist in msdb.
    $jobQuery = "SELECT name FROM dbo.sysjobs WHERE category_id IN " +
        "(SELECT category_id FROM dbo.syscategories WHERE name = N'Report Server')"
    $jobs = @(Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query $jobQuery)
    $subscriptionsPresent = $jobs.Count -gt 0

    # Aggregate: Success only when every check passed.
    $success = -not (
        ($reportResults | Where-Object { -not $_.Success }) -or
        ($dataSourceResults | Where-Object { -not $_.Connected }) -or
        (-not $subscriptionsPresent)
    )

    [pscustomobject]@{
        Reports              = @($reportResults)
        DataSources          = @($dataSourceResults)
        SubscriptionsPresent = $subscriptionsPresent
        Success              = $success
    }
}
