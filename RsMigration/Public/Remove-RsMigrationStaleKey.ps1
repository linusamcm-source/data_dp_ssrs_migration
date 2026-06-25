function Remove-RsMigrationStaleKey {
    <#
    .SYNOPSIS
        Removes the stale source scale-out row from dbo.Keys after a DB restore (B11).
    .DESCRIPTION
        After restoring the ReportServer database, dbo.Keys lists BOTH the old source
        instance and the new target instance, which makes Standard edition error with
        "scale-out not supported". This deletes only the stale source row.

        It first SELECTs Client, MachineName, InstallationID FROM dbo.Keys (returned to
        the caller for verification) and only then issues a parameterised DELETE scoped
        to the supplied -MachineName with InstallationID IS NOT NULL (impl-doc 7.7).

        It refuses to delete anything (throws) when the request is unsafe:
          a) -MachineName equals the active target machine (-ActiveMachineName),
          b) no row in dbo.Keys matches -MachineName (nothing to remove), or
          c) every row in dbo.Keys matches -MachineName (the delete would empty the table).
    .PARAMETER SqlInstance
        Target SQL Server instance hosting the ReportServer database.
    .PARAMETER Database
        ReportServer database name.
    .PARAMETER MachineName
        The stale source machine name whose key row should be removed.
    .PARAMETER ActiveMachineName
        The active target machine name, which must never be deleted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter(Mandatory)]
        [string]$ActiveMachineName
    )

    # Guard (a): never delete the active target's own key row. This is decidable
    # from the inputs alone, so refuse before touching the database.
    if ($MachineName -eq $ActiveMachineName) {
        throw "Refusing to delete dbo.Keys row for '$MachineName': it is the active target machine."
    }

    $selectQuery = 'SELECT Client, MachineName, InstallationID FROM dbo.Keys'
    $rows = @(Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query $selectQuery)

    $matching = @($rows | Where-Object { $_.MachineName -eq $MachineName })

    # Guard (b): nothing matches -> nothing to delete.
    if ($matching.Count -eq 0) {
        throw "Refusing to delete: no dbo.Keys row matches MachineName '$MachineName'."
    }

    # Guard (c): every row matches -> the delete would empty dbo.Keys.
    if ($matching.Count -eq $rows.Count) {
        throw "Refusing to delete: every dbo.Keys row matches MachineName '$MachineName'; this would empty the table."
    }

    if ($PSCmdlet.ShouldProcess("$SqlInstance/$Database", "DELETE stale dbo.Keys row for MachineName '$MachineName'")) {
        $deleteQuery = 'DELETE FROM dbo.Keys WHERE MachineName = @MachineName AND InstallationID IS NOT NULL'
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query $deleteQuery `
            -SqlParameter @{ MachineName = $MachineName }
    }

    return $rows
}
