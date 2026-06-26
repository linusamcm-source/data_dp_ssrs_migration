#Requires -Modules Pester

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Tests build an in-memory SecureString from a literal password to satisfy the -KeyPassword contract.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Expected* / mocked auto-param values are consumed inside nested Should -Invoke -ParameterFilter scriptblocks the analyzer does not trace.')]
param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force

    # AC5 (static half): the orchestrator must build every path with
    # Join-RsMigrationPath, never bake a literal UNC / drive path into the source.
    # A literal cannot be proven absent by mocking, so it is grepped from source.
    $script:RunbookSource = Join-Path $script:ModuleRoot 'Public' 'Invoke-RsMigration.ps1'
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# CONTRACT THIS SUITE PINS (stated for the GREEN engineer)
#
# Invoke-RsMigration is the native PowerShell runbook that REPLACES the
# retired Python runbook orchestrator. It sequences the toolkit's OWN per-phase
# PUBLIC cmdlets IN-PROCESS (no child pwsh process), aborting on the first failure.
#
# REQUIRED PHASE ORDER (each phase calls the toolkit wrapper, not a bare lib cmdlet):
#   Backup-RsMigrationKey -> Backup-RsMigrationDatabase -> Copy-RsMigrationBackup
#   -> Restore-RsMigrationDatabase -> Set-RsMigrationDatabase -> Restore-RsMigrationKey
#   -> Remove-RsMigrationStaleKey -> Import-RsMigrationSubscription
#   -> Invoke-RsMigrationValidation
#
# CHOSEN PARAMETER NAMES (match these in GREEN):
#   SourceSqlInstance, TargetSqlInstance, SourceSharePath, TargetSharePath,
#   KeyFile (.snk file NAME), ReportServerBak, ReportServerTempDbBak (.bak file
#   NAMES), KeyPassword ([SecureString]), DatabaseServerName, DatabaseName,
#   MachineName (stale), ActiveMachineName, ReportItem ([string[]] render list),
#   DataSource ([string[]] data-source list), SourceReportPortalUri,
#   TargetReportPortalUri, IncludeSubscription ([string[]]), DryRun ([switch]).
#   It MUST NOT expose VaultName / AzureBaseUrl / Username / Password.
#
# PATH THREADING:
#   * The .snk KEY path is the FULL path built by Join-RsMigrationPath from
#     SourceSharePath + KeyFile, threaded IDENTICALLY as -KeyPath into BOTH
#     Backup-RsMigrationKey and Restore-RsMigrationKey (the real, un-mocked
#     Join-RsMigrationPath is used).
#   * The .bak databases thread SHARE ROOTS + FILE NAMES (never full paths):
#     Backup-RsMigrationDatabase gets -SqlInstance SourceSqlInstance,
#     -SourceSharePath, -ReportServerBak, -ReportServerTempDbBak;
#     Restore-RsMigrationDatabase gets -SqlInstance TargetSqlInstance,
#     -TargetSharePath + the bak names; Copy-RsMigrationBackup gets both shares
#     + the bak names. Those cmdlets join internally.
#   * Set-RsMigrationDatabase gets -DatabaseServerName / -Name (=DatabaseName);
#     Remove-RsMigrationStaleKey gets -SqlInstance TargetSqlInstance, -Database
#     (=DatabaseName), -MachineName, -ActiveMachineName; both key cmdlets get
#     -KeyPassword; Invoke-RsMigrationValidation gets -ReportPortalUri
#     (=TargetReportPortalUri).
#
# ABORT-ON-FAILURE: when a mutating phase throws, the runbook performs no later
# phase and throws a terminating error whose message names the failing cmdlet.
#
# DRY-RUN: -DryRun runs ONLY Export-RsMigrationInventory + Invoke-RsMigrationValidation
# and NONE of the mutating phase cmdlets.
# -----------------------------------------------------------------------------

Describe 'Invoke-RsMigration parameter contract (AC4)' {

    It 'is defined as a public cmdlet' {
        Get-Command Invoke-RsMigration -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'exposes every required parameter' {
        $keys = (Get-Command Invoke-RsMigration).Parameters.Keys
        foreach ($p in @(
                'SourceSqlInstance', 'TargetSqlInstance', 'SourceSharePath', 'TargetSharePath',
                'KeyFile', 'ReportServerBak', 'ReportServerTempDbBak', 'KeyPassword',
                'DatabaseServerName', 'DatabaseName', 'MachineName', 'ActiveMachineName',
                'ReportItem', 'DataSource', 'SourceReportPortalUri', 'TargetReportPortalUri',
                'IncludeSubscription', 'DryRun')) {
            $keys | Should -Contain $p
        }
    }

    It 'types -KeyPassword as [SecureString]' {
        (Get-Command Invoke-RsMigration).Parameters['KeyPassword'].ParameterType |
            Should -Be ([securestring])
    }

    It 'types -IncludeSubscription as [string[]]' {
        (Get-Command Invoke-RsMigration).Parameters['IncludeSubscription'].ParameterType |
            Should -Be ([string[]])
    }

    It 'types -ReportItem and -DataSource as [string[]]' {
        (Get-Command Invoke-RsMigration).Parameters['ReportItem'].ParameterType |
            Should -Be ([string[]])
        (Get-Command Invoke-RsMigration).Parameters['DataSource'].ParameterType |
            Should -Be ([string[]])
    }

    It 'types -DryRun as [switch]' {
        (Get-Command Invoke-RsMigration).Parameters['DryRun'].ParameterType |
            Should -Be ([switch])
    }

    It 'does NOT expose the decommissioned Key Vault / Azure / NTLM parameters' {
        $keys = (Get-Command Invoke-RsMigration).Parameters.Keys
        $keys | Should -Not -Contain 'VaultName'
        $keys | Should -Not -Contain 'AzureBaseUrl'
        $keys | Should -Not -Contain 'Username'
        $keys | Should -Not -Contain 'Password'
    }
}

Describe 'Invoke-RsMigration' {

    # ---- AC1: the nine phases run in exactly the required order --------------
    Context 'AC1 sequences the nine phase cmdlets in the required order' {

        It 'invokes Backup-Key -> Backup-DB -> Copy -> Restore-DB -> Set-DB -> Restore-Key -> Remove-StaleKey -> Import-Sub -> Validate' {
            InModuleScope RsMigration {
                $script:CallOrder = [System.Collections.Generic.List[string]]::new()

                Mock Backup-RsMigrationKey { $script:CallOrder.Add('Backup-RsMigrationKey') }
                Mock Backup-RsMigrationDatabase { $script:CallOrder.Add('Backup-RsMigrationDatabase') }
                Mock Copy-RsMigrationBackup { $script:CallOrder.Add('Copy-RsMigrationBackup') }
                Mock Restore-RsMigrationDatabase { $script:CallOrder.Add('Restore-RsMigrationDatabase') }
                Mock Set-RsMigrationDatabase { $script:CallOrder.Add('Set-RsMigrationDatabase') }
                Mock Restore-RsMigrationKey { $script:CallOrder.Add('Restore-RsMigrationKey') }
                Mock Remove-RsMigrationStaleKey { $script:CallOrder.Add('Remove-RsMigrationStaleKey') }
                Mock Import-RsMigrationSubscription { $script:CallOrder.Add('Import-RsMigrationSubscription') }
                Mock Invoke-RsMigrationValidation {
                    $script:CallOrder.Add('Invoke-RsMigrationValidation')
                    [pscustomobject]@{ Success = $true }
                }
                # Inventory is a DRY-RUN-only phase; it must NOT run in a normal migration.
                Mock Export-RsMigrationInventory { $script:CallOrder.Add('Export-RsMigrationInventory') }

                $splat = @{
                    SourceSqlInstance     = 'SOURCESQL'
                    TargetSqlInstance     = 'TARGETSQL'
                    SourceSharePath       = '\\source\rsbackup'
                    TargetSharePath       = '\\target\rsbackup'
                    KeyFile               = 'ReportServer.snk'
                    ReportServerBak       = 'ReportServer.bak'
                    ReportServerTempDbBak = 'ReportServerTempDB.bak'
                    KeyPassword           = (ConvertTo-SecureString 'p@ss' -AsPlainText -Force)
                    DatabaseServerName    = 'TARGETSQL'
                    DatabaseName          = 'ReportServer'
                    MachineName           = 'OLDHOST'
                    ActiveMachineName     = 'NEWHOST'
                    ReportItem            = @('/Sales/Orders')
                    DataSource            = @('/Sales/DS')
                    SourceReportPortalUri = 'https://source/reports'
                    TargetReportPortalUri = 'https://target/reports'
                    IncludeSubscription   = @('Daily sales')
                }

                Invoke-RsMigration @splat

                $expectedOrder = @(
                    'Backup-RsMigrationKey'
                    'Backup-RsMigrationDatabase'
                    'Copy-RsMigrationBackup'
                    'Restore-RsMigrationDatabase'
                    'Set-RsMigrationDatabase'
                    'Restore-RsMigrationKey'
                    'Remove-RsMigrationStaleKey'
                    'Import-RsMigrationSubscription'
                    'Invoke-RsMigrationValidation'
                )

                ($script:CallOrder -join ' -> ') | Should -Be ($expectedOrder -join ' -> ')

                # A normal (non-dry-run) migration never runs the inventory phase.
                Should -Invoke Export-RsMigrationInventory -Times 0 -Exactly
            }
        }
    }

    # ---- Output hygiene: the validation result is the sole output -----------
    Context 'returns the validation result and suppresses other phase output' {

        It 'returns exactly the Invoke-RsMigrationValidation result, with no leaked phase output' {
            InModuleScope RsMigration {
                $script:ValidationResult = [pscustomobject]@{ Success = $true; Report = 'render+probe ok' }

                # Every other phase emits junk (stale-key rows, summaries, noise)
                # that MUST NOT leak into the runbook's pipeline output.
                Mock Backup-RsMigrationKey { 'backup-key-noise' }
                Mock Backup-RsMigrationDatabase { 'backup-db-noise' }
                Mock Copy-RsMigrationBackup { 'copy-noise' }
                Mock Restore-RsMigrationDatabase { 'restore-db-noise' }
                Mock Set-RsMigrationDatabase { 'set-db-noise' }
                Mock Restore-RsMigrationKey { 'restore-key-noise' }
                Mock Remove-RsMigrationStaleKey { [pscustomobject]@{ RemovedStaleKey = 'OLDHOST' } }
                Mock Import-RsMigrationSubscription { [pscustomobject]@{ Imported = 2 } }
                Mock Invoke-RsMigrationValidation { $script:ValidationResult }

                $splat = @{
                    SourceSqlInstance     = 'SOURCESQL'
                    TargetSqlInstance     = 'TARGETSQL'
                    SourceSharePath       = '\\source\rsbackup'
                    TargetSharePath       = '\\target\rsbackup'
                    KeyFile               = 'ReportServer.snk'
                    ReportServerBak       = 'ReportServer.bak'
                    ReportServerTempDbBak = 'ReportServerTempDB.bak'
                    KeyPassword           = (ConvertTo-SecureString 'p@ss' -AsPlainText -Force)
                    DatabaseServerName    = 'TARGETSQL'
                    DatabaseName          = 'ReportServer'
                    MachineName           = 'OLDHOST'
                    ActiveMachineName     = 'NEWHOST'
                    ReportItem            = @('/Sales/Orders')
                    DataSource            = @('/Sales/DS')
                    SourceReportPortalUri = 'https://source/reports'
                    TargetReportPortalUri = 'https://target/reports'
                    IncludeSubscription   = @('Daily sales')
                }

                $result = Invoke-RsMigration @splat

                # Exactly one object surfaces (no interleaved phase rows)...
                @($result).Count | Should -Be 1
                # ...and it is the very validation object the validation phase returned.
                [object]::ReferenceEquals($result, $script:ValidationResult) | Should -BeTrue
                $result.Success | Should -BeTrue
            }
        }
    }

    # ---- AC2: abort on the first failing phase ------------------------------
    Context 'AC2 aborts on the first failing phase and names it' {

        It 'runs no later phase and throws an error naming the failing cmdlet when Restore-RsMigrationDatabase fails' {
            InModuleScope RsMigration {
                Mock Backup-RsMigrationKey { }
                Mock Backup-RsMigrationDatabase { }
                Mock Copy-RsMigrationBackup { }
                Mock Restore-RsMigrationDatabase { throw 'simulated restore failure' }
                Mock Set-RsMigrationDatabase { }
                Mock Restore-RsMigrationKey { }
                Mock Remove-RsMigrationStaleKey { }
                Mock Import-RsMigrationSubscription { }
                Mock Invoke-RsMigrationValidation { [pscustomobject]@{ Success = $true } }

                $splat = @{
                    SourceSqlInstance     = 'SOURCESQL'
                    TargetSqlInstance     = 'TARGETSQL'
                    SourceSharePath       = '\\source\rsbackup'
                    TargetSharePath       = '\\target\rsbackup'
                    KeyFile               = 'ReportServer.snk'
                    ReportServerBak       = 'ReportServer.bak'
                    ReportServerTempDbBak = 'ReportServerTempDB.bak'
                    KeyPassword           = (ConvertTo-SecureString 'p@ss' -AsPlainText -Force)
                    DatabaseServerName    = 'TARGETSQL'
                    DatabaseName          = 'ReportServer'
                    MachineName           = 'OLDHOST'
                    ActiveMachineName     = 'NEWHOST'
                    ReportItem            = @('/Sales/Orders')
                    DataSource            = @('/Sales/DS')
                    SourceReportPortalUri = 'https://source/reports'
                    TargetReportPortalUri = 'https://target/reports'
                    IncludeSubscription   = @('Daily sales')
                }

                # The failing phase name (its cmdlet) is surfaced in the terminating
                # error, and the ORIGINAL exception is preserved as the inner exception.
                $err = { Invoke-RsMigration @splat } |
                    Should -Throw -ExpectedMessage '*Restore-RsMigrationDatabase*' -PassThru
                $err.Exception.InnerException | Should -Not -BeNullOrEmpty
                $err.Exception.InnerException.Message | Should -Match 'simulated restore failure'

                # Phases up to and including the failing one ran...
                Should -Invoke Backup-RsMigrationKey -Times 1 -Exactly
                Should -Invoke Backup-RsMigrationDatabase -Times 1 -Exactly
                Should -Invoke Copy-RsMigrationBackup -Times 1 -Exactly
                Should -Invoke Restore-RsMigrationDatabase -Times 1 -Exactly

                # ...and NO phase after the failure was invoked.
                Should -Invoke Set-RsMigrationDatabase -Times 0 -Exactly
                Should -Invoke Restore-RsMigrationKey -Times 0 -Exactly
                Should -Invoke Remove-RsMigrationStaleKey -Times 0 -Exactly
                Should -Invoke Import-RsMigrationSubscription -Times 0 -Exactly
                Should -Invoke Invoke-RsMigrationValidation -Times 0 -Exactly
            }
        }
    }

    # ---- AC3: dry-run runs only the read-only phases ------------------------
    Context 'AC3 -DryRun runs only inventory + validation, no mutating phases' {

        It 'invokes Export-RsMigrationInventory and Invoke-RsMigrationValidation and zero mutating cmdlets' {
            InModuleScope RsMigration {
                Mock Export-RsMigrationInventory { }
                Mock Invoke-RsMigrationValidation { [pscustomobject]@{ Success = $true } }

                Mock Backup-RsMigrationKey { }
                Mock Backup-RsMigrationDatabase { }
                Mock Copy-RsMigrationBackup { }
                Mock Restore-RsMigrationDatabase { }
                Mock Set-RsMigrationDatabase { }
                Mock Restore-RsMigrationKey { }
                Mock Remove-RsMigrationStaleKey { }
                Mock Import-RsMigrationSubscription { }

                $splat = @{
                    SourceSqlInstance     = 'SOURCESQL'
                    TargetSqlInstance     = 'TARGETSQL'
                    SourceSharePath       = '\\source\rsbackup'
                    TargetSharePath       = '\\target\rsbackup'
                    KeyFile               = 'ReportServer.snk'
                    ReportServerBak       = 'ReportServer.bak'
                    ReportServerTempDbBak = 'ReportServerTempDB.bak'
                    KeyPassword           = (ConvertTo-SecureString 'p@ss' -AsPlainText -Force)
                    DatabaseServerName    = 'TARGETSQL'
                    DatabaseName          = 'ReportServer'
                    MachineName           = 'OLDHOST'
                    ActiveMachineName     = 'NEWHOST'
                    ReportItem            = @('/Sales/Orders')
                    DataSource            = @('/Sales/DS')
                    SourceReportPortalUri = 'https://source/reports'
                    TargetReportPortalUri = 'https://target/reports'
                    IncludeSubscription   = @('Daily sales')
                    DryRun                = $true
                }

                Invoke-RsMigration @splat

                # Only the read-only phases run.
                Should -Invoke Export-RsMigrationInventory -Times 1 -Exactly
                Should -Invoke Invoke-RsMigrationValidation -Times 1 -Exactly

                # Every mutating phase is skipped.
                Should -Invoke Backup-RsMigrationKey -Times 0 -Exactly
                Should -Invoke Backup-RsMigrationDatabase -Times 0 -Exactly
                Should -Invoke Copy-RsMigrationBackup -Times 0 -Exactly
                Should -Invoke Restore-RsMigrationDatabase -Times 0 -Exactly
                Should -Invoke Set-RsMigrationDatabase -Times 0 -Exactly
                Should -Invoke Restore-RsMigrationKey -Times 0 -Exactly
                Should -Invoke Remove-RsMigrationStaleKey -Times 0 -Exactly
                Should -Invoke Import-RsMigrationSubscription -Times 0 -Exactly
            }
        }
    }

    # ---- AC5: parameters are threaded into the right phase params -----------
    Context 'AC5 threads inputs into each phase (verified by mock argument capture)' {

        It 'builds the .snk key path with Join-RsMigrationPath and threads inputs into every phase' {
            InModuleScope RsMigration {
                Mock Backup-RsMigrationKey { }
                Mock Backup-RsMigrationDatabase { }
                Mock Copy-RsMigrationBackup { }
                Mock Restore-RsMigrationDatabase { }
                Mock Set-RsMigrationDatabase { }
                Mock Restore-RsMigrationKey { }
                Mock Remove-RsMigrationStaleKey { }
                Mock Import-RsMigrationSubscription { }
                Mock Invoke-RsMigrationValidation { [pscustomobject]@{ Success = $true } }

                $keyPwd = ConvertTo-SecureString 'p@ss' -AsPlainText -Force

                $splat = @{
                    SourceSqlInstance     = 'SOURCESQL'
                    TargetSqlInstance     = 'TARGETSQL'
                    SourceSharePath       = '\\source\rsbackup'
                    TargetSharePath       = '\\target\rsbackup'
                    KeyFile               = 'ReportServer.snk'
                    ReportServerBak       = 'ReportServer.bak'
                    ReportServerTempDbBak = 'ReportServerTempDB.bak'
                    KeyPassword           = $keyPwd
                    DatabaseServerName    = 'DBSRV'
                    DatabaseName          = 'ReportServer'
                    MachineName           = 'OLDHOST'
                    ActiveMachineName     = 'NEWHOST'
                    ReportItem            = @('/Sales/Orders')
                    DataSource            = @('/Sales/DS')
                    SourceReportPortalUri = 'https://source/reports'
                    TargetReportPortalUri = 'https://target/reports'
                    IncludeSubscription   = @('Daily sales')
                }

                # The expected FULL key path uses the real, un-mocked Join-RsMigrationPath.
                $expectedKeyPath = Join-RsMigrationPath -Share $splat.SourceSharePath -FileName $splat.KeyFile
                $expectedKeyPath | Should -Not -BeNullOrEmpty

                Invoke-RsMigration @splat

                # Key cmdlets: same FULL Join-built -KeyPath + the SecureString password into BOTH.
                Should -Invoke Backup-RsMigrationKey -Times 1 -Exactly -ParameterFilter {
                    $KeyPath -eq $expectedKeyPath -and $KeyPassword -eq $keyPwd
                }
                Should -Invoke Restore-RsMigrationKey -Times 1 -Exactly -ParameterFilter {
                    $KeyPath -eq $expectedKeyPath -and $KeyPassword -eq $keyPwd
                }

                # Backup-DB: source instance + SHARE ROOT + bak FILE NAMES (joins internally).
                Should -Invoke Backup-RsMigrationDatabase -Times 1 -Exactly -ParameterFilter {
                    $SqlInstance -eq 'SOURCESQL' -and
                    $SourceSharePath -eq '\\source\rsbackup' -and
                    $ReportServerBak -eq 'ReportServer.bak' -and
                    $ReportServerTempDbBak -eq 'ReportServerTempDB.bak'
                }

                # Copy: both shares + bak file names.
                Should -Invoke Copy-RsMigrationBackup -Times 1 -Exactly -ParameterFilter {
                    $SourceSharePath -eq '\\source\rsbackup' -and
                    $TargetSharePath -eq '\\target\rsbackup' -and
                    $ReportServerBak -eq 'ReportServer.bak' -and
                    $ReportServerTempDbBak -eq 'ReportServerTempDB.bak'
                }

                # Restore-DB: target instance + TARGET share root + bak file names.
                Should -Invoke Restore-RsMigrationDatabase -Times 1 -Exactly -ParameterFilter {
                    $SqlInstance -eq 'TARGETSQL' -and
                    $TargetSharePath -eq '\\target\rsbackup' -and
                    $ReportServerBak -eq 'ReportServer.bak' -and
                    $ReportServerTempDbBak -eq 'ReportServerTempDB.bak'
                }

                # Set-DB: -DatabaseServerName / -Name (= DatabaseName).
                Should -Invoke Set-RsMigrationDatabase -Times 1 -Exactly -ParameterFilter {
                    $DatabaseServerName -eq 'DBSRV' -and $Name -eq 'ReportServer'
                }

                # Stale-key cleanup: target instance, DatabaseName, both machine names.
                Should -Invoke Remove-RsMigrationStaleKey -Times 1 -Exactly -ParameterFilter {
                    $SqlInstance -eq 'TARGETSQL' -and
                    $Database -eq 'ReportServer' -and
                    $MachineName -eq 'OLDHOST' -and
                    $ActiveMachineName -eq 'NEWHOST'
                }

                # Subscription import: both portals + the include allow-list.
                Should -Invoke Import-RsMigrationSubscription -Times 1 -Exactly -ParameterFilter {
                    $SourceReportPortalUri -eq 'https://source/reports' -and
                    $TargetReportPortalUri -eq 'https://target/reports' -and
                    $IncludeSubscription -contains 'Daily sales'
                }

                # Validation: render list, data-source list, and the TARGET portal.
                Should -Invoke Invoke-RsMigrationValidation -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports' -and
                    $ReportItem -contains '/Sales/Orders' -and
                    $DataSource -contains '/Sales/DS'
                }
            }
        }
    }
}

Describe 'Invoke-RsMigration source contract (AC5 - no hardcoded path/UNC literal)' {

    It 'exists and bakes in no literal UNC / drive path (all paths via Join-RsMigrationPath)' {
        Test-Path $script:RunbookSource |
            Should -BeTrue -Because 'Invoke-RsMigration.ps1 must exist for the orchestrator contract to hold'
        if (Test-Path $script:RunbookSource) {
            $content = Get-Content -LiteralPath $script:RunbookSource -Raw
            $content | Should -Not -Match '\\\\'        # no \\server UNC literal
            $content | Should -Not -Match '[A-Za-z]:\\'  # no C:\ drive-path literal
        }
    }
}
