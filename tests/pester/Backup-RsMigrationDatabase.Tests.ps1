#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Backup-RsMigrationDatabase (Public)' {

    # Post-PS3 contract: back ReportServer / ReportServerTempDB up to .bak files on
    # the SOURCE fileshare using the current Windows identity. One Backup-DbaDatabase
    # call per database; the full backup-file path is carried on -FilePath (the
    # dbatools idiom for a specific output file) and is produced by
    # Join-RsMigrationPath from -SourceSharePath. No Azure blob URL, no SqlCredential.
    Context 'fileshare backup' {

        It 'backs up ReportServer to the source-share ReportServer.bak path on -FilePath' {
            InModuleScope RsMigration {
                Mock Backup-DbaDatabase {}

                Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                    -SourceSharePath '\\SOURCEVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Backup-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    "$SqlInstance" -eq 'SOURCEVM' -and
                    $Database -eq 'ReportServer' -and
                    $FilePath -eq '\\SOURCEVM\FileShare\ReportServer.bak'
                }
            }
        }

        It 'backs up ReportServerTempDB to the source-share ReportServerTempDB.bak path on -FilePath' {
            InModuleScope RsMigration {
                Mock Backup-DbaDatabase {}

                Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                    -SourceSharePath '\\SOURCEVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Backup-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    "$SqlInstance" -eq 'SOURCEVM' -and
                    $Database -eq 'ReportServerTempDB' -and
                    $FilePath -eq '\\SOURCEVM\FileShare\ReportServerTempDB.bak'
                }
            }
        }

        It 'makes one Backup-DbaDatabase call per database (twice total)' {
            InModuleScope RsMigration {
                Mock Backup-DbaDatabase {}

                Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                    -SourceSharePath '\\SOURCEVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Backup-DbaDatabase -Times 2 -Exactly
            }
        }

        It 'uses the current Windows identity (no -SqlCredential) and no Azure blob URL' {
            InModuleScope RsMigration {
                Mock Backup-DbaDatabase {}

                Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                    -SourceSharePath '\\SOURCEVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                Should -Invoke Backup-DbaDatabase -Times 2 -Exactly -ParameterFilter {
                    # -AzureBaseUrl is an alias of -StorageBaseUrl; assert the real
                    # parameter is never bound (no blob), and no SQL credential is
                    # passed (current Windows identity only).
                    $null -eq $SqlCredential -and $null -eq $StorageBaseUrl
                }
            }
        }

        It 'passes the migration-critical backup flags (-Type Full -CopyOnly -CompressBackup -Checksum -EnableException) on every call' {
            InModuleScope RsMigration {
                Mock Backup-DbaDatabase {}

                Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                    -SourceSharePath '\\SOURCEVM\FileShare' `
                    -ReportServerBak 'ReportServer.bak' `
                    -ReportServerTempDbBak 'ReportServerTempDB.bak'

                # Guard against a regression silently dropping any of the backup
                # rules: both calls must carry all five flags.
                Should -Invoke Backup-DbaDatabase -Times 2 -Exactly -ParameterFilter {
                    $Type -eq 'Full' -and
                    $CopyOnly -and
                    $CompressBackup -and
                    $Checksum -and
                    $EnableException
                }
            }
        }
    }

    # Pin the post-PS3 parameter contract: the fileshare params must exist and the
    # decommissioned Azure params (Model/AzureBaseUrl) must be gone. This fails fast
    # if a future change reintroduces a blob parameter or renames a share param.
    Context 'parameter contract' {

        It 'exposes the fileshare params and no Azure (Model/AzureBaseUrl) params' {
            $params = (Get-Command Backup-RsMigrationDatabase).Parameters.Keys

            foreach ($expected in @('SourceSharePath', 'ReportServerBak', 'ReportServerTempDbBak')) {
                $params | Should -Contain $expected
            }
            foreach ($forbidden in @('Model', 'AzureBaseUrl')) {
                $params | Should -Not -Contain $forbidden
            }
        }
    }
}

Describe 'Azure blob backup/restore fully removed (PS3 cross-cutting)' {

    BeforeAll {
        $script:ModuleSource = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    }

    It 'has deleted the New-RsMigrationBlobCredential.ps1 private helper' {
        $cred = Join-Path $script:ModuleSource 'Private' 'New-RsMigrationBlobCredential.ps1'
        Test-Path -Path $cred | Should -BeFalse
    }

    It 'contains no Azure blob references anywhere under RsMigration/' {
        $hits = Get-ChildItem -Path $script:ModuleSource -Recurse -Filter '*.ps1' -File |
            Select-String -SimpleMatch -Pattern @(
                'AzureBaseUrl', 'New-RsMigrationBlobCredential', 'blob', 'TO URL'
            )
        $hits | Should -BeNullOrEmpty
    }

    It 'hardcodes no UNC literal in production scripts (paths come from Join-RsMigrationPath params)' {
        # A UNC literal is two backslashes followed by a host character. The only
        # place a backslash-joined path is legitimately assembled is
        # Join-RsMigrationPath (from its parameters), so that file is exempt.
        $hits = Get-ChildItem -Path $script:ModuleSource -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.Name -ne 'Join-RsMigrationPath.ps1' } |
            Select-String -Pattern '\\\\[A-Za-z0-9]'
        $hits | Should -BeNullOrEmpty
    }
}
