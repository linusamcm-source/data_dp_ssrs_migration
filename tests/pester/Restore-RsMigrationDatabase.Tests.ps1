#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Restore-RsMigrationDatabase (Public)' {

    # Post-PS3 contract: restore ReportServer / ReportServerTempDB from the .bak
    # files on the TARGET fileshare, under their identical original names, with
    # -WithReplace, using the current Windows identity. Each restore -Path is
    # produced by Join-RsMigrationPath from -TargetSharePath. No Azure blob URL,
    # no SqlCredential.
    Context 'fileshare restore' {

        It 'restores ReportServer from the target-share ReportServer.bak path under the identical name with -WithReplace' {
            InModuleScope RsMigration {
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -TargetSharePath '\\TARGETVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Restore-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    # -SqlInstance binds as a dbatools [DbaInstanceParameter];
                    # compare its stringified form.
                    "$SqlInstance" -eq 'TARGETVM' -and
                    $Path -eq '\\TARGETVM\FileShare\ReportServer.bak' -and
                    $DatabaseName -eq 'ReportServer' -and
                    $WithReplace
                }
            }
        }

        It 'restores ReportServerTempDB from the target-share ReportServerTempDB.bak path under the identical name with -WithReplace' {
            InModuleScope RsMigration {
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -TargetSharePath '\\TARGETVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Restore-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    "$SqlInstance" -eq 'TARGETVM' -and
                    $Path -eq '\\TARGETVM\FileShare\ReportServerTempDB.bak' -and
                    $DatabaseName -eq 'ReportServerTempDB' -and
                    $WithReplace
                }
            }
        }

        It 'invokes Restore-DbaDatabase exactly once per database (twice total)' {
            InModuleScope RsMigration {
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -TargetSharePath '\\TARGETVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Restore-DbaDatabase -Times 2 -Exactly
            }
        }

        It 'uses the current Windows identity (no -SqlCredential)' {
            InModuleScope RsMigration {
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -TargetSharePath '\\TARGETVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Restore-DbaDatabase -Times 2 -Exactly -ParameterFilter {
                    $null -eq $SqlCredential
                }
            }
        }
    }

    # The identical-name requirement is retained from the pre-PS3 contract: the
    # target databases must keep their original ReportServer / ReportServerTempDB
    # names, so any other -Database name is rejected up front and nothing is
    # restored. The expected-message assertion makes this a right-reason check
    # against the new parameter set (a missing-parameter binding error would not
    # mention the database names).
    Context 'identical-name guard' {

        It 'throws (and restores nothing) when -Database contains a name outside ReportServer/ReportServerTempDB' {
            InModuleScope RsMigration {
                Mock Restore-DbaDatabase {}

                {
                    Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                        -TargetSharePath '\\TARGETVM\FileShare' `
                        -ReportServerBak 'ReportServer.bak' `
                        -ReportServerTempDbBak 'ReportServerTempDB.bak' `
                        -Database 'ReportServer', 'SomeOtherDb'
                } | Should -Throw -ExpectedMessage '*ReportServer*'

                Should -Invoke Restore-DbaDatabase -Times 0 -Exactly
            }
        }
    }

    # Pin the post-PS3 parameter contract: the fileshare params must exist and the
    # decommissioned Azure params (Model/AzureBaseUrl) must be gone. This fails fast
    # if a future change reintroduces a blob parameter or renames a share param.
    Context 'parameter contract' {

        It 'exposes the fileshare params and no Azure (Model/AzureBaseUrl) params' {
            $params = (Get-Command Restore-RsMigrationDatabase).Parameters.Keys

            foreach ($expected in @('TargetSharePath', 'ReportServerBak', 'ReportServerTempDbBak')) {
                $params | Should -Contain $expected
            }
            foreach ($forbidden in @('Model', 'AzureBaseUrl')) {
                $params | Should -Not -Contain $forbidden
            }
        }
    }
}
