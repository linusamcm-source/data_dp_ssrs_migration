function Restore-RsMigrationDatabase {
    <#
    .SYNOPSIS
        Restores the Reporting Services databases from the .bak files on the target
        SMB share, preserving the original database names.
    .DESCRIPTION
        Restores ReportServer and ReportServerTempDB from their .bak files on the
        target share. Each database is restored under its identical original name
        with -WithReplace, the restore -Path for each being produced by
        Join-RsMigrationPath from -TargetSharePath. No SQL credential is passed, so
        each restore runs as the current Windows identity.

        It guards the identical-name requirement: it throws if asked to restore
        under any database name other than ReportServer / ReportServerTempDB.
    .PARAMETER SqlInstance
        The target SQL Server instance to restore ReportServer /
        ReportServerTempDB onto.
    .PARAMETER TargetSharePath
        The SMB share the .bak files were copied to. The restore -Path for each
        database is Join-RsMigrationPath of this share and the matching .bak name.
    .PARAMETER ReportServerBak
        The ReportServer backup file name.
    .PARAMETER ReportServerTempDbBak
        The ReportServerTempDB backup file name.
    .PARAMETER Database
        The databases to restore. Defaults to ReportServer, ReportServerTempDB and
        is constrained to that set: a name outside it throws, guarding the
        identical-name requirement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$TargetSharePath,

        [Parameter(Mandatory)]
        [string]$ReportServerBak,

        [Parameter(Mandatory)]
        [string]$ReportServerTempDbBak,

        [string[]]$Database = @('ReportServer', 'ReportServerTempDB')
    )

    # Guard the identical-name requirement: the target databases must keep the
    # original ReportServer / ReportServerTempDB names, so reject any other name
    # up front and restore nothing.
    $allowed = @('ReportServer', 'ReportServerTempDB')
    foreach ($db in $Database) {
        if ($db -notin $allowed) {
            throw "Restore-RsMigrationDatabase only restores ReportServer / ReportServerTempDB under their original names (identical-name requirement); refusing '$db'."
        }
    }

    $bakFor = @{
        'ReportServer'       = $ReportServerBak
        'ReportServerTempDB' = $ReportServerTempDbBak
    }

    foreach ($db in $Database) {
        $path = Join-RsMigrationPath -Share $TargetSharePath -FileName $bakFor[$db]
        # dbatools swallows errors as warnings by default; -EnableException makes a
        # restore failure terminating so callers (e.g. the runbook) see it and abort.
        Restore-DbaDatabase -SqlInstance $SqlInstance `
            -Path $path `
            -DatabaseName $db `
            -WithReplace -EnableException
    }
}
