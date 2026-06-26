#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'RsMigration.psd1'
    Import-Module $script:ManifestPath -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'RsMigration manifest and import' {
    It 'imports from the manifest without error' {
        { Import-Module $script:ManifestPath -Force } | Should -Not -Throw
    }

    It 'declares the required modules without Az.KeyVault' {
        $data = Import-PowerShellDataFile -Path $script:ManifestPath
        $required = @($data.RequiredModules | ForEach-Object {
            if ($_ -is [hashtable]) { $_.ModuleName } else { $_ }
        })
        $required | Should -Contain 'ReportingServicesTools'
        $required | Should -Contain 'dbatools'
        $required | Should -Not -Contain 'Az.KeyVault'
    }
}

Describe 'Public function auto-export' {
    BeforeAll {
        $script:StubPath = Join-Path $script:ModuleRoot 'Public' 'Get-Stub.ps1'
        @'
function Get-Stub {
    [CmdletBinding()]
    param()
    'stub'
}
'@ | Set-Content -Path $script:StubPath -Encoding utf8
        Import-Module $script:ManifestPath -Force
    }

    AfterAll {
        Remove-Item -Path $script:StubPath -Force -ErrorAction SilentlyContinue
        Import-Module $script:ManifestPath -Force
    }

    It 'exports a newly dropped Public/Get-Stub.ps1 with no manifest edit' {
        $exported = Get-Command -Module RsMigration | Select-Object -ExpandProperty Name
        $exported | Should -Contain 'Get-Stub'
    }
}

Describe 'Underlying cmdlet resolution' {
    It 'resolves every wrapped cmdlet after required modules are installed' {
        {
            Get-Command Backup-RsEncryptionKey, Restore-RsEncryptionKey, New-DbaCredential,
                Backup-DbaDatabase, Restore-DbaDatabase, Set-RsDatabase, Invoke-DbaQuery,
                Get-RsRestItemDataSource, Set-RsRestItemDataSource -ErrorAction Stop
        } | Should -Not -Throw
    }
}
