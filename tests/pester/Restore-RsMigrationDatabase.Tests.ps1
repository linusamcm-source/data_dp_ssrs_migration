#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force

    # Test-only helper: build a SecureString from a literal to exercise the
    # credential-forwarding path. PSAvoidUsingConvertToSecureStringWithPlainText
    # is suppressed here because no plaintext secret is ever persisted - this is a
    # throwaway value created solely to assert how the wrapper forwards it. The
    # secret is built in the test (outer) scope and passed into InModuleScope via
    # -Parameters, because functions defined here are not visible inside the
    # module's session state.
    function script:New-PlainSecret {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingConvertToSecureStringWithPlainText', '',
            Justification = 'Test-only literal SecureString to exercise the credential-forwarding path.')]
        [OutputType([System.Security.SecureString])]
        param([Parameter(Mandatory)][string]$Text)
        ConvertTo-SecureString $Text -AsPlainText -Force
    }
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Restore-RsMigrationDatabase (Public)' {

    # AC1: creates the blob credential for the chosen model on the target instance
    # BEFORE restoring.
    Context 'blob credential creation' {
        It 'calls New-RsMigrationBlobCredential for the chosen model on the target instance before restoring' {
            $sas = New-PlainSecret -Text 'sas-token-value'
            InModuleScope RsMigration -Parameters @{ Sas = $sas } {
                param($Sas)
                $script:order = [System.Collections.Generic.List[string]]::new()
                Mock New-RsMigrationBlobCredential { $script:order.Add('cred') }
                Mock Restore-DbaDatabase { $script:order.Add('restore') }

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'StorageKey' -SecurePassword $Sas

                # Credential created once, on the target instance, for the chosen model.
                Should -Invoke New-RsMigrationBlobCredential -Times 1 -Exactly -ParameterFilter {
                    $SqlInstance -eq 'TARGETVM' -and
                    $Model -eq 'StorageKey' -and
                    $ContainerUrl -eq 'https://rsmigsa.blob.core.windows.net/rsmig'
                }

                # ...and it ran before the first restore.
                $script:order[0] | Should -Be 'cred'
            }
        }

        It 'defaults to the SAS model and forwards the SecurePassword to the credential helper' {
            $sas = New-PlainSecret -Text 'sas-token-value'
            InModuleScope RsMigration -Parameters @{ Sas = $sas } {
                param($Sas)
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -SecurePassword $Sas

                Should -Invoke New-RsMigrationBlobCredential -Times 1 -Exactly -ParameterFilter {
                    $Model -eq 'SAS' -and
                    $null -ne $SecurePassword -and
                    ([pscredential]::new('u', $SecurePassword)).GetNetworkCredential().Password -eq 'sas-token-value'
                }
            }
        }

        It 'supports the ManagedIdentity model with no SecurePassword' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'ManagedIdentity'

                Should -Invoke New-RsMigrationBlobCredential -Times 1 -Exactly -ParameterFilter {
                    $Model -eq 'ManagedIdentity' -and $null -eq $SecurePassword
                }
            }
        }
    }

    # AC2: one restore per DB, each -WithReplace, -Path <container>/<db>.bak,
    # -DatabaseName equal to the original (identical) name.
    Context 'restore calls' {
        It 'restores ReportServer from the container ReportServer.bak path under the identical name with -WithReplace' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'ManagedIdentity'

                Should -Invoke Restore-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    # Restore-DbaDatabase's -SqlInstance binds as a dbatools
                    # [DbaInstanceParameter], so compare its stringified form.
                    "$SqlInstance" -eq 'TARGETVM' -and
                    $Path -eq 'https://rsmigsa.blob.core.windows.net/rsmig/ReportServer.bak' -and
                    $DatabaseName -eq 'ReportServer' -and
                    $WithReplace
                }
            }
        }

        It 'restores ReportServerTempDB from the container ReportServerTempDB.bak path under the identical name with -WithReplace' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'ManagedIdentity'

                Should -Invoke Restore-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    # -SqlInstance binds as a dbatools [DbaInstanceParameter];
                    # compare its stringified form.
                    "$SqlInstance" -eq 'TARGETVM' -and
                    $Path -eq 'https://rsmigsa.blob.core.windows.net/rsmig/ReportServerTempDB.bak' -and
                    $DatabaseName -eq 'ReportServerTempDB' -and
                    $WithReplace
                }
            }
        }

        It 'invokes Restore-DbaDatabase exactly once per database (twice total)' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'ManagedIdentity'

                Should -Invoke Restore-DbaDatabase -Times 2 -Exactly
            }
        }

        It 'trims a trailing slash on the container URL so the path has no double slash' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                    -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig/' `
                    -Model 'ManagedIdentity'

                Should -Invoke Restore-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                    $Path -eq 'https://rsmigsa.blob.core.windows.net/rsmig/ReportServer.bak'
                }
            }
        }
    }

    # AC3: throws (restores nothing) if asked to restore under a non-standard DB name.
    Context 'identical-name guard' {
        It 'throws when -Database contains a name other than ReportServer/ReportServerTempDB' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                {
                    Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                        -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                        -Database 'ReportServer', 'SomeOtherDb' `
                        -Model 'ManagedIdentity'
                } | Should -Throw

                Should -Invoke Restore-DbaDatabase -Times 0 -Exactly
            }
        }

        It 'does not create a credential or restore when the DB-name guard trips' {
            InModuleScope RsMigration {
                Mock New-RsMigrationBlobCredential {}
                Mock Restore-DbaDatabase {}

                {
                    Restore-RsMigrationDatabase -SqlInstance 'TARGETVM' `
                        -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                        -Database 'NotAReportServerDb' `
                        -Model 'ManagedIdentity'
                } | Should -Throw

                Should -Invoke New-RsMigrationBlobCredential -Times 0 -Exactly
                Should -Invoke Restore-DbaDatabase -Times 0 -Exactly
            }
        }
    }
}
