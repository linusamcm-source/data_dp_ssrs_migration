function Set-RsMigrationDatabase {
    <#
    .SYNOPSIS
        Points PBIRS at the already-restored ReportServer database (B9).
    .DESCRIPTION
        Wraps Set-RsDatabase -IsExistingDatabase (configure-only; never creates a
        database) to bind the PBIRS instance to the restored DB, then performs the
        service restart that Set-RsDatabase deliberately omits - the restored-DB
        connection only takes effect after PowerBIReportServer is restarted
        (impl-doc 7.5). The restart is routed through the Restart-RsService seam so
        it remains mockable on non-Windows test hosts.
    .PARAMETER DatabaseServerName
        SQL Server hosting the restored ReportServer database.
    .PARAMETER Name
        Database name to bind (e.g. ReportServer).
    .PARAMETER DatabaseCredentialType
        How the report server authenticates to the DB. Defaults to ServiceAccount.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'DatabaseCredentialType',
        Justification = 'DatabaseCredentialType is an enum-like selector (Windows|SQL|ServiceAccount), not a secret.')]
    param(
        [Parameter(Mandatory)]
        [string]$DatabaseServerName,

        [Parameter(Mandatory)]
        [string]$Name,

        [ValidateSet('Windows', 'SQL', 'ServiceAccount')]
        [string]$DatabaseCredentialType = 'ServiceAccount'
    )

    if (-not $PSCmdlet.ShouldProcess($DatabaseServerName, "Point PBIRS at existing database '$Name' and restart")) {
        return
    }

    # -ErrorAction Stop so a non-terminating Set-RsDatabase failure does not fall
    # through to restart the service as if the rebind had succeeded.
    Set-RsDatabase -DatabaseServerName $DatabaseServerName -Name $Name -IsExistingDatabase `
        -DatabaseCredentialType $DatabaseCredentialType `
        -ReportServerInstance 'PBIRS' -ReportServerVersion PowerBIReportServer -ErrorAction Stop

    # Set-RsDatabase does not restart the report server; the new connection only
    # takes effect after a restart (impl-doc 7.5).
    Restart-RsService -Name 'PowerBIReportServer'
}
