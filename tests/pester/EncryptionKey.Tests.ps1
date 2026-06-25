#Requires -Modules Pester

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Test builds an in-memory PSCredential from a literal password to exercise the -Credential rejection path.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'KeyPath is passed into the nested Should -Throw scriptblock; the analyzer does not trace that usage.')]
param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Backup-RsMigrationKey' {
    BeforeEach {
        # Backup-RsEncryptionKey writes the .snk to -KeyPath; use a real temp path
        # so the wrapper's post-backup read-back-and-encode step has a file to read.
        $script:KeyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rsmig-{0}.snk" -f ([guid]::NewGuid()))
    }

    AfterEach {
        Remove-Item -Path $script:KeyPath -Force -ErrorAction SilentlyContinue
    }

    # AC: calls Backup-RsEncryptionKey with -Password from Get-KeyVaultSecret and the supplied -KeyPath.
    It 'calls Backup-RsEncryptionKey with the Key Vault password and supplied KeyPath' {
        InModuleScope RsMigration -Parameters @{ ExpectedKeyPath = $script:KeyPath } {
            param($ExpectedKeyPath)
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Backup-RsEncryptionKey { [System.IO.File]::WriteAllBytes($KeyPath, [byte[]](1, 2, 3)) }
            Mock Set-AzKeyVaultSecret { }

            Backup-RsMigrationKey -KeyPath $ExpectedKeyPath `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk'

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $Password -eq 'snk-pwd' -and $KeyPath -eq $ExpectedKeyPath
            }
        }
    }

    # AC: defaults the SOURCE connection params via Resolve-RsConnection (PBIRS-first).
    It 'forwards Resolve-RsConnection defaults to Backup-RsEncryptionKey when no connection params are supplied' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Backup-RsEncryptionKey { [System.IO.File]::WriteAllBytes($KeyPath, [byte[]](1, 2, 3)) }
            Mock Set-AzKeyVaultSecret { }

            Backup-RsMigrationKey -KeyPath $KeyPath `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk'

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'PBIRS' -and $ReportServerVersion -eq 'PowerBIReportServer'
            }
        }
    }

    # AC: forwards caller-supplied SOURCE connection params, overridable to the SSRS source.
    It 'forwards caller-supplied SOURCE connection params (SSRS / SQLServer2019) to Backup-RsEncryptionKey' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Backup-RsEncryptionKey { [System.IO.File]::WriteAllBytes($KeyPath, [byte[]](1, 2, 3)) }
            Mock Set-AzKeyVaultSecret { }

            Backup-RsMigrationKey -KeyPath $KeyPath `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk' `
                -ReportServerInstance 'SSRS' -ReportServerVersion 'SQLServer2019'

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'SSRS' -and $ReportServerVersion -eq 'SQLServer2019'
            }
        }
    }

    # AC: forwards an overridden -ComputerName to the SOURCE connection.
    It 'forwards a caller-supplied -ComputerName to Backup-RsEncryptionKey' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            $sourceHost = 'SOURCEVM'
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Backup-RsEncryptionKey { [System.IO.File]::WriteAllBytes($KeyPath, [byte[]](1, 2, 3)) }
            Mock Set-AzKeyVaultSecret { }

            Backup-RsMigrationKey -KeyPath $KeyPath `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk' `
                -ComputerName $sourceHost

            Should -Invoke Backup-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq $sourceHost
            }
        }
    }

    # AC: on success, pushes the .snk bytes to Key Vault as base64 via Set-AzKeyVaultSecret.
    It 'pushes the .snk bytes to Key Vault as base64 on success' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            $keyBytes = [byte[]](10, 20, 30, 200, 255)
            $expectedB64 = [System.Convert]::ToBase64String($keyBytes)

            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            # Backup-RsEncryptionKey writes the .snk; simulate by writing the bytes to -KeyPath.
            Mock Backup-RsEncryptionKey { [System.IO.File]::WriteAllBytes($KeyPath, $keyBytes) }.GetNewClosure()
            Mock Set-AzKeyVaultSecret { }

            Backup-RsMigrationKey -KeyPath $KeyPath `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk'

            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq 'rsVault' -and
                $Name -eq 'rsSnk' -and
                ([System.Net.NetworkCredential]::new('', $SecretValue).Password) -eq $expectedB64
            }
        }
    }

    # AC: when Backup-RsEncryptionKey throws, rethrow and do NOT call Set-AzKeyVaultSecret.
    It 'rethrows and does not write to Key Vault when Backup-RsEncryptionKey throws' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Backup-RsEncryptionKey { throw 'WMI BackupEncryptionKey failed (HRESULT 0x80131500)' }
            Mock Set-AzKeyVaultSecret { }

            { Backup-RsMigrationKey -KeyPath $KeyPath `
                    -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk' } |
                Should -Throw '*BackupEncryptionKey failed*'

            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }
    }

    # AC (hardening): a NON-terminating failure from Backup-RsEncryptionKey (the
    # realistic WMI default) must still abort via -ErrorAction Stop, so a stale
    # .snk is never base64'd and pushed to Key Vault.
    It 'does not write to Key Vault when Backup-RsEncryptionKey fails non-terminating' {
        InModuleScope RsMigration -Parameters @{ KeyPath = $script:KeyPath } {
            param($KeyPath)
            # Pre-create a stale .snk so a fall-through would read it and push garbage.
            [System.IO.File]::WriteAllBytes($KeyPath, [byte[]](9, 9, 9))
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            # Non-terminating failure: the backup writes nothing new and only Write-Errors.
            Mock Backup-RsEncryptionKey { Write-Error 'WMI BackupEncryptionKey non-terminating failure' }
            Mock Set-AzKeyVaultSecret { }

            { Backup-RsMigrationKey -KeyPath $KeyPath `
                    -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -SnkSecretName 'rsSnk' } |
                Should -Throw

            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }
    }
}

Describe 'Restore-RsMigrationKey' {
    # AC: calls Restore-RsEncryptionKey with -ReportServerInstance 'PBIRS', -Password from
    #     Get-KeyVaultSecret, -KeyPath, and WITHOUT -Credential.
    It 'calls Restore-RsEncryptionKey with PBIRS, the Key Vault password, KeyPath, and no -Credential' {
        InModuleScope RsMigration {
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Restore-RsEncryptionKey { }

            Restore-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd'

            Should -Invoke Restore-RsEncryptionKey -Times 1 -Exactly -ParameterFilter {
                $ReportServerInstance -eq 'PBIRS' -and
                $Password -eq 'snk-pwd' -and
                $KeyPath -eq 'C:\rs\ReportServer.snk' -and
                -not $PSBoundParameters.ContainsKey('Credential')
            }
        }
    }

    # AC: throws a descriptive error if a -Credential value is supplied (enforces local-restart path).
    It 'throws a descriptive error when -Credential is supplied and never calls Restore-RsEncryptionKey' {
        InModuleScope RsMigration {
            Mock Get-KeyVaultSecret { 'snk-pwd' } -ParameterFilter { -not $AsBytes }
            Mock Restore-RsEncryptionKey { }

            $cred = [System.Management.Automation.PSCredential]::new(
                'dom\svc', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))

            { Restore-RsMigrationKey -KeyPath 'C:\rs\ReportServer.snk' `
                    -VaultName 'rsVault' -PasswordSecretName 'rsKeyPwd' -Credential $cred } |
                Should -Throw '*local*'

            Should -Invoke Restore-RsEncryptionKey -Times 0 -Exactly
        }
    }
}
