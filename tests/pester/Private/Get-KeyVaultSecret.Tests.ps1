#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Get-KeyVaultSecret' {
    It 'returns the plaintext secret value' {
        InModuleScope RsMigration {
            Mock Get-AzKeyVaultSecret { 'super-secret' } -ParameterFilter { $AsPlainText }
            $result = Get-KeyVaultSecret -VaultName 'V' -Name 'N'
            $result | Should -Be 'super-secret'
            Should -Invoke Get-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq 'V' -and $Name -eq 'N' -and $AsPlainText
            }
        }
    }

    It 'returns base64-decoded bytes with -AsBytes' {
        InModuleScope RsMigration {
            $expected = [byte[]](1, 2, 3, 4, 250)
            $b64 = [System.Convert]::ToBase64String($expected)
            Mock Get-AzKeyVaultSecret { $b64 } -ParameterFilter { $AsPlainText }

            $result = Get-KeyVaultSecret -VaultName 'V' -Name 'N' -AsBytes

            $result | Should -BeOfType [byte]
            [byte[]]$result | Should -Be $expected
        }
    }
}
