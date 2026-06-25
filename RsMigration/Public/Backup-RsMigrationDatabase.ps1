function Backup-RsMigrationDatabase {
    <#
    .SYNOPSIS
        Backs up the Reporting Services databases TO URL (impl-doc section 7.3 / B7).
    .DESCRIPTION
        Creates the blob credential for the chosen auth model via the private
        New-RsMigrationBlobCredential helper, then backs up ReportServer and
        ReportServerTempDB to the Azure blob container with the native
        BACKUP TO URL options the migration requires:
        -Type Full -CopyOnly -CompressBackup -Checksum (impl-doc section 4 "Rules":
        COPY_ONLY, COMPRESSION, CHECKSUM).
    .PARAMETER SqlInstance
        The source SQL Server instance hosting ReportServer / ReportServerTempDB.
    .PARAMETER AzureBaseUrl
        The blob container URL backups are written to (Backup-DbaDatabase
        -AzureBaseUrl, an alias of -StorageBaseUrl).
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

        [ValidateSet('SAS', 'StorageKey', 'ManagedIdentity')]
        [string]$Model = 'SAS',

        [System.Security.SecureString]$SecurePassword
    )

    $credParams = @{
        SqlInstance  = $SqlInstance
        ContainerUrl = $AzureBaseUrl
        Model        = $Model
    }
    if ($PSBoundParameters.ContainsKey('SecurePassword')) {
        $credParams.SecurePassword = $SecurePassword
    }
    New-RsMigrationBlobCredential @credParams

    Backup-DbaDatabase -SqlInstance $SqlInstance `
        -Database 'ReportServer', 'ReportServerTempDB' `
        -AzureBaseUrl $AzureBaseUrl `
        -Type Full -CopyOnly -CompressBackup -Checksum
}
