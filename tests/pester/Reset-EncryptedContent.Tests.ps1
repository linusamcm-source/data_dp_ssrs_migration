#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Reset-RsMigrationEncryptedContent' {

    Context 'AC1: builds the rskeymgmt.exe path string' {
        It 'constructs the default MSRS15.PBIRS path and passes it to the helper with -d' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                Reset-RsMigrationEncryptedContent -Force

                $expectedPath = 'C:\Program Files\Microsoft SQL Server\MSRS15.PBIRS\Reporting Services\ReportServer\bin\rskeymgmt.exe'
                Should -Invoke Invoke-RsKeyMgmt -Times 1 -Exactly -ParameterFilter {
                    $ExePath -eq $expectedPath -and $Arguments -contains '-d'
                }
            }
        }

        It 'uses an overridden SQL major-version segment in the constructed path' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                Reset-RsMigrationEncryptedContent -Force -SqlMajorVersion 'MSRS16'

                $expectedPath = 'C:\Program Files\Microsoft SQL Server\MSRS16.PBIRS\Reporting Services\ReportServer\bin\rskeymgmt.exe'
                Should -Invoke Invoke-RsKeyMgmt -Times 1 -Exactly -ParameterFilter {
                    $ExePath -eq $expectedPath
                }
            }
        }
    }

    Context 'AC2: confirmation gating' {
        It 'invokes the helper exactly once with -Force' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                Reset-RsMigrationEncryptedContent -Force

                Should -Invoke Invoke-RsKeyMgmt -Times 1 -Exactly
            }
        }
    }

    Context 'AC3: -WhatIf' {
        It 'invokes the helper zero times under -WhatIf' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                Reset-RsMigrationEncryptedContent -WhatIf

                Should -Invoke Invoke-RsKeyMgmt -Times 0 -Exactly
            }
        }

        It 'does NOT destroy under -WhatIf even when -Force is supplied' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                # -Force must not defeat -WhatIf on the catalog-destroying cmdlet.
                Reset-RsMigrationEncryptedContent -Force -WhatIf

                Should -Invoke Invoke-RsKeyMgmt -Times 0 -Exactly
            }
        }
    }

    Context 'AC4: non-zero exit code surfaces as terminating error' {
        It 'throws when the helper reports a non-zero exit code' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 5 }

                { Reset-RsMigrationEncryptedContent -Force } | Should -Throw
            }
        }

        It 'does not throw when the helper reports exit code 0' {
            InModuleScope RsMigration {
                Mock Invoke-RsKeyMgmt { 0 }

                { Reset-RsMigrationEncryptedContent -Force } | Should -Not -Throw
            }
        }
    }
}
