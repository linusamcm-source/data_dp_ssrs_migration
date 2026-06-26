#Requires -Modules Pester

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Tests build in-memory SecureStrings from literal passwords to exercise the new -KeyPassword contract.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Expected* values are consumed inside nested Should -Invoke -ParameterFilter scriptblocks the analyzer does not trace.')]
param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force

    # Source artefacts PS1 rewrites - used by the static source-contract assertions
    # below. After PS1 the Get-KeyVaultSecret helper is gone and Az.KeyVault is no
    # longer required, so "no Key Vault is invoked" can only be proven by grepping
    # the source (a deleted/absent command cannot be mocked for Should -Invoke).
    $script:BackupSource  = Join-Path $script:ModuleRoot 'Public' 'Backup-RsMigrationKey.ps1'
    $script:RestoreSource = Join-Path $script:ModuleRoot 'Public' 'Restore-RsMigrationKey.ps1'
    $script:HelperSource  = Join-Path $script:ModuleRoot 'Private' 'Get-KeyVaultSecret.ps1'
    $script:ManifestPath  = Join-Path $script:ModuleRoot 'RsMigration.psd1'
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Backup-RsMigrationKey parameter contract' {
    # AC2: -KeyPassword [SecureString] and -KeyPath present; Key Vault params gone.
    It 'exposes -KeyPassword typed as [SecureString]' {
        $param = (Get-Command Backup-RsMigrationKey).Parameters['KeyPassword']
        $param | Should -Not -BeNullOrEmpty
        $param.ParameterType | Should -Be ([securestring])
    }

    It 'exposes -KeyPath' {
        (Get-Command Backup-RsMigrationKey).Parameters.Keys | Should -Contain 'KeyPath'
    }

    It 'no longer exposes the Key Vault parameters' {
        $keys = (Get-Command Backup-RsMigrationKey).Parameters.Keys
        $keys | Should -Not -Contain 'VaultName'
        $keys | Should -Not -Contain 'PasswordSecretName'
        $keys | Should -Not -Contain 'SnkSecretName'
    }
}

Describe 'Restore-RsMigrationKey parameter contract' {
    # AC3: -KeyPassword [SecureString] present; Key Vault params gone.
    It 'exposes -KeyPassword typed as [SecureString]' {
        $param = (Get-Command Restore-RsMigrationKey).Parameters['KeyPassword']
        $param | Should -Not -BeNullOrEmpty
        $param.ParameterType | Should -Be ([securestring])
    }

    It 'no longer exposes the Key Vault parameters' {
        $keys = (Get-Command Restore-RsMigrationKey).Parameters.Keys
        $keys | Should -Not -Contain 'VaultName'
        $keys | Should -Not -Contain 'PasswordSecretName'
    }
}

Describe 'Backup-RsMigrationKey' {
    # AC4: passes the supplied -KeyPath and the DECRYPTED -KeyPassword straight to
    #      Backup-RsEncryptionKey -Password. No read-back, no secret write.
    It 'calls Backup-RsEncryptionKey with the decrypted KeyPassword and supplied KeyPath' {
        InModuleScope RsMigration -Parameters @{ ExpectedPwd = 'snk-pwd'; ExpectedKeyPath = 'C:\rs\ReportServer.snk' } {
            param($ExpectedPwd, $ExpectedKeyPath)
            Mock Backup-RsEncryptionKey { }

            Backup-RsMigrationKey -KeyPath $ExpectedKeyPath `
                -KeyPassword (ConvertTo-SecureString $ExpectedPwd -AsPlainText -Force)

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $Password -eq $ExpectedPwd -and $KeyPath -eq $ExpectedKeyPath
            }
        }
    }

    # AC6: when -KeyPassword is omitted, prompt for it via Read-Host -AsSecureString
    #      and forward the decrypted value to Backup-RsEncryptionKey.
    It 'prompts for the password via Read-Host -AsSecureString when -KeyPassword is omitted' {
        InModuleScope RsMigration -Parameters @{ ExpectedKeyPath = 'C:\rs\ReportServer.snk' } {
            param($ExpectedKeyPath)
            Mock Backup-RsEncryptionKey { }
            Mock Read-Host { ConvertTo-SecureString 'from-prompt' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

            Backup-RsMigrationKey -KeyPath $ExpectedKeyPath

            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $Password -eq 'from-prompt' -and $KeyPath -eq $ExpectedKeyPath
            }
        }
    }

    # Preserved (pre-existing, non-Key-Vault) behaviour: SOURCE connection defaults
    # flow through Resolve-RsConnection (PBIRS-first), overridable to the SSRS source.
    It 'forwards Resolve-RsConnection PBIRS-first defaults to Backup-RsEncryptionKey when no connection params are supplied' {
        InModuleScope RsMigration {
            Mock Backup-RsEncryptionKey { }

            Backup-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                -KeyPassword (ConvertTo-SecureString 'snk-pwd' -AsPlainText -Force)

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'PBIRS' -and $ReportServerVersion -eq 'PowerBIReportServer'
            }
        }
    }

    It 'forwards caller-supplied SOURCE connection params (SSRS / SQLServer2019) to Backup-RsEncryptionKey' {
        InModuleScope RsMigration {
            Mock Backup-RsEncryptionKey { }

            Backup-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                -KeyPassword (ConvertTo-SecureString 'snk-pwd' -AsPlainText -Force) `
                -ReportServerInstance 'SSRS' -ReportServerVersion 'SQLServer2019'

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'SSRS' -and $ReportServerVersion -eq 'SQLServer2019'
            }
        }
    }

    It 'forwards a caller-supplied -ComputerName to Backup-RsEncryptionKey' {
        InModuleScope RsMigration {
            $sourceHost = 'SOURCEVM'
            Mock Backup-RsEncryptionKey { }

            Backup-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                -KeyPassword (ConvertTo-SecureString 'snk-pwd' -AsPlainText -Force) `
                -ComputerName $sourceHost

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq $sourceHost
            }
        }
    }
}

Describe 'Restore-RsMigrationKey' {
    # AC5: calls Restore-RsEncryptionKey for PBIRS, reading the .snk from -KeyPath and
    #      passing the DECRYPTED KeyPassword as -Password, WITHOUT -Credential.
    It 'calls Restore-RsEncryptionKey with PBIRS, the decrypted KeyPassword, KeyPath, and no -Credential' {
        InModuleScope RsMigration -Parameters @{ ExpectedPwd = 'snk-pwd'; ExpectedKeyPath = 'C:\rs\ReportServer.snk' } {
            param($ExpectedPwd, $ExpectedKeyPath)
            Mock Restore-RsEncryptionKey { }

            Restore-RsMigrationKey -KeyPath $ExpectedKeyPath `
                -KeyPassword (ConvertTo-SecureString $ExpectedPwd -AsPlainText -Force)

            Should -Invoke Restore-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'PBIRS' -and
                $Password -eq $ExpectedPwd -and
                $KeyPath -eq $ExpectedKeyPath -and
                -not $PSBoundParameters.ContainsKey('Credential')
            }
        }
    }

    # AC6: when -KeyPassword is omitted, prompt for it via Read-Host -AsSecureString.
    It 'prompts for the password via Read-Host -AsSecureString when -KeyPassword is omitted' {
        InModuleScope RsMigration -Parameters @{ ExpectedKeyPath = 'C:\rs\ReportServer.snk' } {
            param($ExpectedKeyPath)
            Mock Restore-RsEncryptionKey { }
            Mock Read-Host { ConvertTo-SecureString 'from-prompt' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

            Restore-RsMigrationKey -KeyPath $ExpectedKeyPath

            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
            Should -Invoke Restore-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $Password -eq 'from-prompt' -and $KeyPath -eq $ExpectedKeyPath
            }
        }
    }

    # Preserved behaviour: supplying -Credential forces the fragile remote restart
    # path, so the wrapper rejects it with a descriptive local-only error.
    It 'throws a descriptive local-only error when -Credential is supplied and never calls Restore-RsEncryptionKey' {
        InModuleScope RsMigration {
            Mock Restore-RsEncryptionKey { }

            $cred = [System.Management.Automation.PSCredential]::new(
                'dom\svc', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))

            { Restore-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                    -KeyPassword (ConvertTo-SecureString 'snk-pwd' -AsPlainText -Force) `
                    -Credential $cred } |
                Should -Throw '*local*'

            Should -Invoke Restore-RsEncryptionKey -Times 0 -Exactly
        }
    }
}

Describe 'Key Vault decommission (source contract)' {
    # AC1: the Private Get-KeyVaultSecret helper is deleted.
    It 'has removed the Private Get-KeyVaultSecret helper' {
        Test-Path -LiteralPath $script:HelperSource | Should -BeFalse
    }

    # AC1 / step 2: neither cmdlet references any Key Vault cmdlet or the deleted helper.
    It 'Backup-RsMigrationKey.ps1 references no Key Vault cmdlet or Get-KeyVaultSecret helper' {
        $content = Get-Content -LiteralPath $script:BackupSource -Raw
        $content | Should -Not -Match 'Get-AzKeyVaultSecret'
        $content | Should -Not -Match 'Set-AzKeyVaultSecret'
        $content | Should -Not -Match 'Get-KeyVaultSecret'
    }

    It 'Restore-RsMigrationKey.ps1 references no Key Vault cmdlet or Get-KeyVaultSecret helper' {
        $content = Get-Content -LiteralPath $script:RestoreSource -Raw
        $content | Should -Not -Match 'Get-AzKeyVaultSecret'
        $content | Should -Not -Match 'Set-AzKeyVaultSecret'
        $content | Should -Not -Match 'Get-KeyVaultSecret'
    }

    # AC7: -KeyPath is caller-supplied; no hardcoded UNC host literal in either file.
    It 'Backup-RsMigrationKey.ps1 contains no hardcoded UNC host literal' {
        (Get-Content -LiteralPath $script:BackupSource -Raw) | Should -Not -Match '\\\\[A-Za-z0-9]'
    }

    It 'Restore-RsMigrationKey.ps1 contains no hardcoded UNC host literal' {
        (Get-Content -LiteralPath $script:RestoreSource -Raw) | Should -Not -Match '\\\\[A-Za-z0-9]'
    }

    # AC8: the manifest no longer requires Az.KeyVault.
    It 'RsMigration.psd1 RequiredModules no longer lists Az.KeyVault (only ReportingServicesTools and dbatools remain)' {
        $data = Import-PowerShellDataFile -Path $script:ManifestPath
        $required = @($data.RequiredModules | ForEach-Object {
                if ($_ -is [hashtable]) { $_.ModuleName } else { $_ }
            })
        $required | Should -Not -Contain 'Az.KeyVault'
        $required | Should -Contain 'ReportingServicesTools'
        $required | Should -Contain 'dbatools'
    }
}
