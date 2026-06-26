function Copy-RsMigrationBackup {
    <#
    .SYNOPSIS
        Copies the two Reporting Services .bak files from the source SMB share to
        the target SMB share using the current Windows identity.
    .DESCRIPTION
        Builds the exact backslash path for each .bak file on both shares with
        Join-RsMigrationPath, then copies each file with Copy-Item. A copy failure
        is terminating (-ErrorAction Stop) so the original error propagates and the
        caller (e.g. the runbook) aborts rather than continuing the migration.
    .PARAMETER SourceSharePath
        The share the .bak files were backed up to.
    .PARAMETER TargetSharePath
        The share the .bak files are copied to for the restore.
    .PARAMETER ReportServerBak
        The ReportServer backup file name.
    .PARAMETER ReportServerTempDbBak
        The ReportServerTempDB backup file name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceSharePath,

        [Parameter(Mandatory)]
        [string]$TargetSharePath,

        [Parameter(Mandatory)]
        [string]$ReportServerBak,

        [Parameter(Mandatory)]
        [string]$ReportServerTempDbBak
    )

    foreach ($bak in @($ReportServerBak, $ReportServerTempDbBak)) {
        $source = Join-RsMigrationPath -Share $SourceSharePath -FileName $bak
        $destination = Join-RsMigrationPath -Share $TargetSharePath -FileName $bak
        Copy-Item -Path $source -Destination $destination -ErrorAction Stop
    }
}
