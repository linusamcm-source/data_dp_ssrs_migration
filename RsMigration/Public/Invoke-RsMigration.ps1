function Invoke-RsMigration {
    <#
    .SYNOPSIS
        Native PowerShell runbook that sequences the SSRS-to-PBIRS migration
        end-to-end, replacing the retired Python runbook orchestrator.
    .DESCRIPTION
        Calls the toolkit's OWN per-phase public cmdlets in-process (no child
        pwsh process) in the required order, aborting on the first failure:

          1. Backup-RsMigrationKey       2. Backup-RsMigrationDatabase
          3. Copy-RsMigrationBackup      4. Restore-RsMigrationDatabase
          5. Set-RsMigrationDatabase     6. Restore-RsMigrationKey
          7. Remove-RsMigrationStaleKey  8. Import-RsMigrationSubscription
          9. Invoke-RsMigrationValidation

        Every share path is built with Join-RsMigrationPath; the .snk key path
        is joined from -SourceSharePath + -KeyFile and threaded identically into
        both key cmdlets. The .bak databases pass share ROOTS + file NAMES (the
        phase cmdlets join internally). If a phase throws, the runbook performs
        no later phase and re-throws a terminating error naming the failing cmdlet.

        -DryRun runs ONLY the read-only phases (catalog inventory of the SOURCE,
        then validation against the TARGET) and none of the mutating phases,
        mirroring the Python runbook's dry-run contract.
    .PARAMETER SourceSqlInstance
        SQL Server instance backed up from (the SSRS source catalog host).
    .PARAMETER TargetSqlInstance
        SQL Server instance restored to (the PBIRS target catalog host).
    .PARAMETER SourceSharePath
        SMB share root the source backups and the .snk key are written to.
    .PARAMETER TargetSharePath
        SMB share root the backups are copied to and restored from.
    .PARAMETER KeyFile
        File NAME of the encryption-key .snk (joined onto -SourceSharePath).
    .PARAMETER ReportServerBak
        File NAME of the ReportServer database backup.
    .PARAMETER ReportServerTempDbBak
        File NAME of the ReportServerTempDB database backup.
    .PARAMETER KeyPassword
        [SecureString] protecting the .snk; threaded into backup and restore.
        Prompted via Read-Host -AsSecureString when omitted, so unattended
        callers MUST pass it.
    .PARAMETER DatabaseServerName
        SQL Server name PBIRS is pointed at by Set-RsMigrationDatabase.
    .PARAMETER DatabaseName
        Catalog database name (also the -Database for the stale-key cleanup).
    .PARAMETER MachineName
        Stale (old) host name whose key entry is removed from the catalog.
    .PARAMETER ActiveMachineName
        Active (new) host name retained during the stale-key cleanup.
    .PARAMETER ReportItem
        Catalog paths of the report items to render-test during validation.
    .PARAMETER DataSource
        Catalog paths of the data sources to probe during validation.
    .PARAMETER SourceReportPortalUri
        SOURCE report-portal URI (used by the dry-run inventory phase).
    .PARAMETER TargetReportPortalUri
        TARGET report-portal URI (used by subscription import and validation).
    .PARAMETER IncludeSubscription
        Allow-list of subscription names to import; empty imports them all.
    .PARAMETER DryRun
        Run only the read-only inventory + validation phases; mutate nothing.
    .EXAMPLE
        Invoke-RsMigration -SourceSqlInstance $srcSql -TargetSqlInstance $tgtSql `
            -SourceSharePath $srcShare -TargetSharePath $tgtShare `
            -KeyFile ReportServer.snk -ReportServerBak ReportServer.bak `
            -ReportServerTempDbBak ReportServerTempDB.bak -KeyPassword $securePwd `
            -DatabaseServerName $tgtSql -DatabaseName ReportServer `
            -MachineName OLDHOST -ActiveMachineName NEWHOST `
            -ReportItem '/Sales/Orders' -DataSource '/Sales/DS' `
            -SourceReportPortalUri $srcPortal -TargetReportPortalUri $tgtPortal
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceSqlInstance,

        [Parameter(Mandatory)]
        [string]$TargetSqlInstance,

        [Parameter(Mandatory)]
        [string]$SourceSharePath,

        [Parameter(Mandatory)]
        [string]$TargetSharePath,

        [Parameter(Mandatory)]
        [string]$KeyFile,

        [Parameter(Mandatory)]
        [string]$ReportServerBak,

        [Parameter(Mandatory)]
        [string]$ReportServerTempDbBak,

        [SecureString]$KeyPassword,

        [Parameter(Mandatory)]
        [string]$DatabaseServerName,

        [Parameter(Mandatory)]
        [string]$DatabaseName,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter(Mandatory)]
        [string]$ActiveMachineName,

        [Parameter(Mandatory)]
        [string[]]$ReportItem,

        [Parameter(Mandatory)]
        [string[]]$DataSource,

        [Parameter(Mandatory)]
        [string]$SourceReportPortalUri,

        [Parameter(Mandatory)]
        [string]$TargetReportPortalUri,

        [string[]]$IncludeSubscription,

        [switch]$DryRun
    )

    # The .snk key path is the only FULL path the runbook builds; every other
    # phase receives share roots + file names and joins internally.
    $keyPath = Join-RsMigrationPath -Share $SourceSharePath -FileName $KeyFile

    # Validation runs against the TARGET in both a real run and a dry-run, so
    # build its splat first (-Database is left at the cmdlet's msdb default).
    $validationSplat = @{
        ReportPortalUri = $TargetReportPortalUri
        ReportItem      = $ReportItem
        DataSource      = $DataSource
        SqlInstance     = $TargetSqlInstance
    }

    if ($DryRun) {
        # Read-only pre-migration check: inventory the SOURCE catalog, then
        # validate the TARGET. No mutating phase runs. The inventory output is
        # suppressed so the validation result is the cmdlet's sole output.
        $null = Export-RsMigrationInventory -ReportPortalUri $SourceReportPortalUri
        return Invoke-RsMigrationValidation @validationSplat
    }

    # Per-phase splats. Both key cmdlets share the SAME $keyPath and the SAME
    # $KeyPassword instance; the .bak phases get share roots + file names.
    $keySplat = @{
        KeyPath     = $keyPath
        KeyPassword = $KeyPassword
    }
    $backupDbSplat = @{
        SqlInstance           = $SourceSqlInstance
        SourceSharePath       = $SourceSharePath
        ReportServerBak       = $ReportServerBak
        ReportServerTempDbBak = $ReportServerTempDbBak
    }
    $copySplat = @{
        SourceSharePath       = $SourceSharePath
        TargetSharePath       = $TargetSharePath
        ReportServerBak       = $ReportServerBak
        ReportServerTempDbBak = $ReportServerTempDbBak
    }
    $restoreDbSplat = @{
        SqlInstance           = $TargetSqlInstance
        TargetSharePath       = $TargetSharePath
        ReportServerBak       = $ReportServerBak
        ReportServerTempDbBak = $ReportServerTempDbBak
    }
    $setDbSplat = @{
        DatabaseServerName = $DatabaseServerName
        Name               = $DatabaseName
    }
    $staleKeySplat = @{
        SqlInstance       = $TargetSqlInstance
        Database          = $DatabaseName
        MachineName       = $MachineName
        ActiveMachineName = $ActiveMachineName
    }
    $subscriptionSplat = @{
        SourceReportPortalUri = $SourceReportPortalUri
        TargetReportPortalUri = $TargetReportPortalUri
        IncludeSubscription   = $IncludeSubscription
    }

    # Ordered phase table: name (for error reporting + command resolution) plus
    # its pre-built splat. Resolving by name lets each phase cmdlet be mocked.
    $phases = @(
        [pscustomobject]@{ Name = 'Backup-RsMigrationKey'; Splat = $keySplat }
        [pscustomobject]@{ Name = 'Backup-RsMigrationDatabase'; Splat = $backupDbSplat }
        [pscustomobject]@{ Name = 'Copy-RsMigrationBackup'; Splat = $copySplat }
        [pscustomobject]@{ Name = 'Restore-RsMigrationDatabase'; Splat = $restoreDbSplat }
        [pscustomobject]@{ Name = 'Set-RsMigrationDatabase'; Splat = $setDbSplat }
        [pscustomobject]@{ Name = 'Restore-RsMigrationKey'; Splat = $keySplat }
        [pscustomobject]@{ Name = 'Remove-RsMigrationStaleKey'; Splat = $staleKeySplat }
        [pscustomobject]@{ Name = 'Import-RsMigrationSubscription'; Splat = $subscriptionSplat }
        [pscustomobject]@{ Name = 'Invoke-RsMigrationValidation'; Splat = $validationSplat }
    )

    # Run each phase in order, aborting on the first failure. The mutating
    # phases' return values are discarded so only the final validation result
    # surfaces as the cmdlet's output.
    $validationResult = $null
    foreach ($phase in $phases) {
        $splat = $phase.Splat
        try {
            if ($phase.Name -eq 'Invoke-RsMigrationValidation') {
                $validationResult = & $phase.Name @splat
            }
            else {
                $null = & $phase.Name @splat
            }
        }
        catch {
            # Preserve the original exception (its type, inner exception and
            # stack trace) as the inner exception while naming the failing phase.
            throw [System.Exception]::new(
                "Invoke-RsMigration aborted at $($phase.Name): $($_.Exception.Message)",
                $_.Exception)
        }
    }

    return $validationResult
}
