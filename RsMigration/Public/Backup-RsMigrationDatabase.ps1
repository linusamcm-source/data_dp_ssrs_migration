function Backup-RsMigrationDatabase {
    <#
    .SYNOPSIS
        Backs up the Reporting Services databases to .bak files on the source SMB
        share using the current Windows identity.
    .DESCRIPTION
        Makes one Backup-DbaDatabase call per database (ReportServer, then
        ReportServerTempDB), writing each backup to its .bak file on the source
        share. The output path is produced by Join-RsMigrationPath from
        -SourceSharePath and carried on -FilePath (the dbatools idiom for a single
        specific output file). No SQL credential is passed, so each backup runs as
        the current Windows identity. The migration's backup rules are preserved:
        -Type Full -CopyOnly -CompressBackup -Checksum.
    .PARAMETER SqlInstance
        The source SQL Server instance hosting ReportServer / ReportServerTempDB.
    .PARAMETER SourceSharePath
        The SMB share the .bak files are written to.
    .PARAMETER ReportServerBak
        The ReportServer backup file name.
    .PARAMETER ReportServerTempDbBak
        The ReportServerTempDB backup file name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$SourceSharePath,

        [Parameter(Mandatory)]
        [string]$ReportServerBak,

        [Parameter(Mandatory)]
        [string]$ReportServerTempDbBak
    )

    $backups = [ordered]@{
        'ReportServer'       = $ReportServerBak
        'ReportServerTempDB' = $ReportServerTempDbBak
    }

    foreach ($entry in $backups.GetEnumerator()) {
        $filePath = Join-RsMigrationPath -Share $SourceSharePath -FileName $entry.Value
        # dbatools 2.8.2: -FilePath takes the complete backup file name including
        # extension; a full instance-relative UNC path is accepted here (vs -Path
        # which is a directory). Confirmed via Get-Help Backup-DbaDatabase.
        # dbatools swallows errors as warnings by default; -EnableException makes a
        # backup failure terminating so callers (e.g. the runbook) see it and abort.
        Backup-DbaDatabase -SqlInstance $SqlInstance `
            -Database $entry.Key `
            -FilePath $filePath `
            -Type Full -CopyOnly -CompressBackup -Checksum -EnableException
    }
}
