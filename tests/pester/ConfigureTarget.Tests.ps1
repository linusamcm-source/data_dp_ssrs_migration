#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Set-RsMigrationDatabase' {
    It 'configures the existing restored DB (configure-only, never create)' {
        InModuleScope RsMigration {
            Mock Set-RsDatabase { }
            Mock Restart-RsService { }

            Set-RsMigrationDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer'

            Should -Invoke Set-RsDatabase -Times 1 -Exactly -ParameterFilter {
                $IsExistingDatabase -and
                $DatabaseServerName -eq 'TARGETSQL' -and
                $Name -eq 'ReportServer' -and
                $ReportServerInstance -eq 'PBIRS' -and
                $ReportServerVersion -eq 'PowerBIReportServer' -and
                $DatabaseCredentialType -eq 'ServiceAccount'
            }
        }
    }

    It 'defaults DatabaseCredentialType to ServiceAccount and allows override' {
        InModuleScope RsMigration {
            Mock Set-RsDatabase { }
            Mock Restart-RsService { }

            Set-RsMigrationDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer' `
                -DatabaseCredentialType 'Windows'

            Should -Invoke Set-RsDatabase -Times 1 -Exactly -ParameterFilter {
                $DatabaseCredentialType -eq 'Windows'
            }
        }
    }

    It 'restarts the PowerBIReportServer service after Set-RsDatabase' {
        InModuleScope RsMigration {
            Mock Set-RsDatabase { }
            Mock Restart-RsService { }

            Set-RsMigrationDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer'

            Should -Invoke Restart-RsService -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'PowerBIReportServer'
            }
        }
    }

    It 'restarts only after the database is pointed (Set-RsDatabase first)' {
        InModuleScope RsMigration {
            $script:order = [System.Collections.Generic.List[string]]::new()
            Mock Set-RsDatabase { $script:order.Add('set') }
            Mock Restart-RsService { $script:order.Add('restart') }

            Set-RsMigrationDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer'

            $script:order[0] | Should -Be 'set'
            $script:order[1] | Should -Be 'restart'
        }
    }

    It 'supports -WhatIf and mutates nothing' {
        InModuleScope RsMigration {
            Mock Set-RsDatabase { }
            Mock Restart-RsService { }

            Set-RsMigrationDatabase -DatabaseServerName 'TARGETSQL' -Name 'ReportServer' -WhatIf

            Should -Invoke Set-RsDatabase -Times 0 -Exactly
            Should -Invoke Restart-RsService -Times 0 -Exactly
        }
    }
}

Describe 'Remove-RsMigrationStaleKey' {
    # A default Keys table (active target row + stale source row) is defined
    # locally inside each InModuleScope block so the Invoke-DbaQuery mock closure
    # can capture it; module-scope mocks cannot see the test file's $script: vars.

    It 'runs the SELECT of dbo.Keys first and returns those rows' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            $rows = Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                -MachineName 'SOURCEVM' -ActiveMachineName 'TARGETVM'

            # Returned rows are the SELECT projection.
            $rows.Count | Should -Be 2
            $rows.MachineName | Should -Contain 'TARGETVM'
            $rows.MachineName | Should -Contain 'SOURCEVM'

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'SELECT\s+Client,\s*MachineName,\s*InstallationID\s+FROM\s+dbo\.Keys'
            }
        }
    }

    It 'deletes only the supplied stale MachineName and only rows with a non-null InstallationID' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                -MachineName 'SOURCEVM' -ActiveMachineName 'TARGETVM'

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'DELETE\s+FROM\s+dbo\.Keys' -and
                $Query -match 'MachineName' -and
                $Query -match 'InstallationID IS NOT NULL' -and
                $SqlParameter.MachineName -eq 'SOURCEVM'
            }
        }
    }

    It 'runs SELECT then DELETE in that order' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') {
                    $calls.Add('select')
                    return $keysRows
                }
                else {
                    $calls.Add('delete')
                }
            }

            Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                -MachineName 'SOURCEVM' -ActiveMachineName 'TARGETVM'

            $calls[0] | Should -Be 'select'
            $calls[1] | Should -Be 'delete'
        }
    }

    It 'supports -WhatIf: runs the SELECT but issues no DELETE' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                -MachineName 'SOURCEVM' -ActiveMachineName 'TARGETVM' -WhatIf

            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter { $Query -match 'SELECT' }
            Should -Invoke Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter { $Query -match 'DELETE' }
        }
    }

    It 'throws and deletes nothing when MachineName equals the active target machine' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            { Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                    -MachineName 'TARGETVM' -ActiveMachineName 'TARGETVM' } |
                Should -Throw '*active*'

            # Self-evidently wrong input: refuse before touching the database at all.
            Should -Invoke Invoke-DbaQuery -Times 0 -Exactly
        }
    }

    It 'throws and deletes nothing when the SELECT returns zero rows for the MachineName' {
        InModuleScope RsMigration {
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'TARGETVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            { Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                    -MachineName 'GHOSTVM' -ActiveMachineName 'TARGETVM' } |
                Should -Throw

            # The function must have run the SELECT to know there were zero matches...
            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'SELECT'
            }
            # ...but must NOT issue the DELETE.
            Should -Invoke Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter {
                $Query -match 'DELETE'
            }
        }
    }

    It 'throws and deletes nothing when the MachineName matches every row (would empty the table)' {
        InModuleScope RsMigration {
            # Every row shares the same machine name -> deleting it empties dbo.Keys.
            $keysRows = @(
                [pscustomobject]@{ Client = 'C1'; MachineName = 'SOURCEVM'; InstallationID = '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ Client = 'C2'; MachineName = 'SOURCEVM'; InstallationID = '22222222-2222-2222-2222-222222222222' }
            )
            Mock Invoke-DbaQuery {
                if ($Query -match 'SELECT') { return $keysRows }
            }

            { Remove-RsMigrationStaleKey -SqlInstance 'TARGETSQL' -Database 'ReportServer' `
                    -MachineName 'SOURCEVM' -ActiveMachineName 'TARGETVM' } |
                Should -Throw

            # The function must have run the SELECT to know it would empty the table...
            Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                $Query -match 'SELECT'
            }
            # ...but must NOT issue the DELETE.
            Should -Invoke Invoke-DbaQuery -Times 0 -Exactly -ParameterFilter {
                $Query -match 'DELETE'
            }
        }
    }
}
