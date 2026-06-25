function Restore-RsMigrationDatabase {
    <#
    .SYNOPSIS
        Restores the Reporting Services databases FROM URL on the target,
        preserving the original database names (impl-doc section 7.4 / B8).
    .DESCRIPTION
        Creates the blob credential for the chosen auth model on the TARGET
        instance via the private New-RsMigrationBlobCredential helper, then
        restores ReportServer and ReportServerTempDB from the Azure blob
        container. Each database is restored under its identical original name
        (impl-doc section 6 B8: "Restore FROM URL on target, identical DB
        names"), with -WithReplace and a -Path of <container>/<db>.bak.

        It guards the identical-name requirement: it throws if asked to restore
        under any database name other than ReportServer / ReportServerTempDB.
    .PARAMETER SqlInstance
        The target SQL Server instance to restore ReportServer /
        ReportServerTempDB onto.
    .PARAMETER AzureBaseUrl
        The blob container URL the .bak files were written to. The restore -Path
        for each database is <AzureBaseUrl>/<db>.bak.
    .PARAMETER Database
        The databases to restore. Defaults to ReportServer, ReportServerTempDB
        and is constrained to that set: a name outside it throws, guarding the
        identical-name requirement.
    .PARAMETER Model
        Blob-auth model passed to New-RsMigrationBlobCredential: SAS (default),
        StorageKey, or ManagedIdentity.
    .PARAMETER SecurePassword
        The SAS token or storage access key as a SecureString (not used for
        ManagedIdentity).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$AzureBaseUrl,

        [string[]]$Database = @('ReportServer', 'ReportServerTempDB'),

        [ValidateSet('SAS', 'StorageKey', 'ManagedIdentity')]
        [string]$Model = 'SAS',

        [System.Security.SecureString]$SecurePassword
    )

    # Guard the identical-name requirement (impl-doc section 6 B8): the target
    # databases must keep the original ReportServer / ReportServerTempDB names,
    # so reject any other name up front and restore nothing.
    $allowed = @('ReportServer', 'ReportServerTempDB')
    foreach ($db in $Database) {
        if ($db -notin $allowed) {
            throw "Restore-RsMigrationDatabase only restores ReportServer / ReportServerTempDB under their original names (identical-name requirement, impl-doc section 6 B8); refusing '$db'."
        }
    }

    $credParams = @{
        SqlInstance  = $SqlInstance
        ContainerUrl = $AzureBaseUrl
        Model        = $Model
    }
    if ($PSBoundParameters.ContainsKey('SecurePassword')) {
        $credParams.SecurePassword = $SecurePassword
    }
    New-RsMigrationBlobCredential @credParams

    $container = $AzureBaseUrl.TrimEnd('/')
    foreach ($db in $Database) {
        # dbatools swallows errors as warnings by default; -EnableException makes
        # a restore failure terminating so callers (e.g. the runbook) see it and
        # abort, matching the Backup-RsMigrationDatabase convention.
        Restore-DbaDatabase -SqlInstance $SqlInstance `
            -Path "$container/$db.bak" `
            -DatabaseName $db `
            -WithReplace -EnableException
    }
}
