function Export-RsMigrationInventory {
    <#
    .SYNOPSIS
        Inventories catalog data sources into a structured report (impl-doc 7.1 /
        runbook A1).
    .DESCRIPTION
        Enumerates every catalog item under -RsFolder via Get-RsRestFolderContent
        (recursively), reads each item's data sources via Get-RsRestItemDataSource,
        and emits one structured inventory record per data source containing the
        item path, data-source name, CredentialRetrieval mode, and connection
        string.

        The cmdlet NEVER emits a password and writes no secret anywhere. Any
        credential embedded in a data source's connection string (Password=/Pwd=)
        is masked (e.g. Password=***) before the record is written, so nothing
        secret reaches the persisted inventory. Stored ('Store') data sources are
        reported like any other so the operator knows a credential exists, but
        re-entering that stored credential on the target is a manual, out-of-band
        operator step performed after migration - it is not automated here. REST
        access uses the RS cmdlets' default current-user (integrated) credentials.
    .PARAMETER ReportPortalUri
        Base URI of the Reporting Services / PBIRS portal (REST v2.0 endpoint).
    .PARAMETER RsFolder
        Root catalog folder to enumerate from. Defaults to '/' (the whole catalog).
    .EXAMPLE
        Export-RsMigrationInventory -ReportPortalUri https://target/reports
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ReportPortalUri,

        [string]$RsFolder = '/'
    )

    $items = Get-RsRestFolderContent -RsFolder $RsFolder -Recurse -ReportPortalUri $ReportPortalUri

    foreach ($item in $items) {
        $dataSources = Get-RsRestItemDataSource -RsItem $item.Path -ReportPortalUri $ReportPortalUri

        foreach ($ds in $dataSources) {
            $connectionString = $ds.ConnectString
            if ($connectionString) {
                # Mask any credential embedded in the connection string (Password=/Pwd=,
                # case-insensitive, any spacing, repeated tokens) before the record is
                # persisted; non-credential key=value pairs are preserved verbatim.
                $connectionString = $connectionString -replace '(?i)(password|pwd)\s*=\s*[^;]*', '$1=***'
            }

            [pscustomobject]@{
                ItemPath            = $item.Path
                DataSourceName      = $ds.Name
                CredentialRetrieval = $ds.CredentialRetrieval
                ConnectionString    = $connectionString
            }
        }
    }
}
