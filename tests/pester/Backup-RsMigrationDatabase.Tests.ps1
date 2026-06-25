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

Describe 'New-RsMigrationBlobCredential (Private helper)' {

    Context 'SAS model' {
        It 'calls New-DbaCredential with the SAS identity and the SAS SecurePassword' {
            $sas = New-PlainSecret -Text 'sas-token-value'
            InModuleScope RsMigration -Parameters @{ Sas = $sas } {
                param($Sas)
                Mock New-DbaCredential {}

                New-RsMigrationBlobCredential -SqlInstance 'SOURCEVM' `
                    -ContainerUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'SAS' -SecurePassword $Sas

                Should -Invoke New-DbaCredential -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq 'SHARED ACCESS SIGNATURE' -and
                    $null -ne $SecurePassword -and
                    ([pscredential]::new('u', $SecurePassword)).GetNetworkCredential().Password -eq 'sas-token-value'
                }
            }
        }
    }

    Context 'StorageKey model' {
        It 'calls New-DbaCredential with the container URL as identity and the access key SecurePassword' {
            $key = New-PlainSecret -Text 'storage-access-key'
            InModuleScope RsMigration -Parameters @{ Key = $key } {
                param($Key)
                Mock New-DbaCredential {}

                New-RsMigrationBlobCredential -SqlInstance 'SOURCEVM' `
                    -ContainerUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'StorageKey' -SecurePassword $Key

                Should -Invoke New-DbaCredential -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq 'https://rsmigsa.blob.core.windows.net/rsmig' -and
                    $null -ne $SecurePassword -and
                    ([pscredential]::new('u', $SecurePassword)).GetNetworkCredential().Password -eq 'storage-access-key'
                }
            }
        }
    }

    Context 'ManagedIdentity model' {
        It 'calls New-DbaCredential with the Managed Identity and NO SecurePassword' {
            InModuleScope RsMigration {
                Mock New-DbaCredential {}

                New-RsMigrationBlobCredential -SqlInstance 'TARGETVM' `
                    -ContainerUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                    -Model 'ManagedIdentity'

                Should -Invoke New-DbaCredential -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq 'Managed Identity' -and
                    $null -eq $SecurePassword -and
                    -not $PSBoundParameters.ContainsKey('SecurePassword')
                }
            }
        }
    }

    Context 'invalid model' {
        It 'rejects an unknown Model value with a terminating ValidateSet error' {
            InModuleScope RsMigration {
                Mock New-DbaCredential {}
                {
                    New-RsMigrationBlobCredential -SqlInstance 'X' `
                        -ContainerUrl 'https://x/c' -Model 'NotAModel'
                } | Should -Throw
                Should -Invoke New-DbaCredential -Times 0 -Exactly
            }
        }
    }
}

Describe 'Backup-RsMigrationDatabase (Public)' {

    It 'backs up ReportServer and ReportServerTempDB TO URL with the required flags' {
        $sas = New-PlainSecret -Text 'sas-token-value'
        InModuleScope RsMigration -Parameters @{ Sas = $sas } {
            param($Sas)
            Mock New-DbaCredential {}
            Mock Backup-DbaDatabase {}

            Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                -Model 'SAS' -SecurePassword $Sas

            Should -Invoke Backup-DbaDatabase -Times 1 -Exactly -ParameterFilter {
                # -AzureBaseUrl is an alias of -StorageBaseUrl; it binds to the real
                # parameter name inside the mock filter.
                $StorageBaseUrl -eq 'https://rsmigsa.blob.core.windows.net/rsmig' -and
                ($Database -contains 'ReportServer') -and
                ($Database -contains 'ReportServerTempDB') -and
                $Type -eq 'Full' -and
                $CopyOnly -and
                $CompressBackup -and
                $Checksum
            }
        }
    }

    It 'creates the blob credential for the chosen model before backing up' {
        $sas = New-PlainSecret -Text 'sas-token-value'
        InModuleScope RsMigration -Parameters @{ Sas = $sas } {
            param($Sas)
            Mock New-DbaCredential {}
            Mock Backup-DbaDatabase {}

            Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                -Model 'SAS' -SecurePassword $Sas

            Should -Invoke New-DbaCredential -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'SHARED ACCESS SIGNATURE'
            }
        }
    }

    It 'supports the ManagedIdentity model with no SecurePassword' {
        InModuleScope RsMigration {
            Mock New-DbaCredential {}
            Mock Backup-DbaDatabase {}

            Backup-RsMigrationDatabase -SqlInstance 'SOURCEVM' `
                -AzureBaseUrl 'https://rsmigsa.blob.core.windows.net/rsmig' `
                -Model 'ManagedIdentity'

            Should -Invoke New-DbaCredential -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'Managed Identity' -and $null -eq $SecurePassword
            }
            Should -Invoke Backup-DbaDatabase -Times 1 -Exactly
        }
    }
}
