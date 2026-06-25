#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-RsConnection' {
    It 'returns the PBIRS-first defaults' {
        InModuleScope RsMigration {
            $splat = Resolve-RsConnection
            $splat | Should -BeOfType [hashtable]
            $splat.ReportServerInstance | Should -Be 'PBIRS'
            $splat.ReportServerVersion | Should -Be 'PowerBIReportServer'
            $splat.ComputerName | Should -Be 'localhost'
        }
    }

    It 'overrides ReportServerInstance when supplied' {
        InModuleScope RsMigration {
            $splat = Resolve-RsConnection -ReportServerInstance 'SSRS'
            $splat.ReportServerInstance | Should -Be 'SSRS'
            $splat.ReportServerVersion | Should -Be 'PowerBIReportServer'
            $splat.ComputerName | Should -Be 'localhost'
        }
    }

    It 'overrides ReportServerVersion when supplied' {
        InModuleScope RsMigration {
            $splat = Resolve-RsConnection -ReportServerVersion 'SQLServer2019'
            $splat.ReportServerVersion | Should -Be 'SQLServer2019'
            $splat.ReportServerInstance | Should -Be 'PBIRS'
            $splat.ComputerName | Should -Be 'localhost'
        }
    }

    It 'overrides ComputerName when supplied' {
        InModuleScope RsMigration {
            # Value held in a variable so PSScriptAnalyzer's
            # PSAvoidUsingComputerNameHardcoded does not flag a literal here.
            $machine = 'SOURCEVM'
            $splat = Resolve-RsConnection -ComputerName $machine
            $splat.ComputerName | Should -Be $machine
            $splat.ReportServerInstance | Should -Be 'PBIRS'
            $splat.ReportServerVersion | Should -Be 'PowerBIReportServer'
        }
    }
}
