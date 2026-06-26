#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Test-RsDataSourceConnection (Private seam)' {

    # Post-PS4 contract: the data-source probe must obtain its REST session from the
    # integrated-auth helper New-RsMigrationRestSession and thread that EXACT session
    # into Test-RsRestItemDataSource via -WebSession. Obtaining the session but then
    # discarding it is a failure, which the reference-equality filter below pins.

    Context 'AC3 routes the probe through the integrated-auth session helper' {

        It 'obtains the session via New-RsMigrationRestSession (passing the portal URI)' {
            InModuleScope RsMigration {
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession { return $sentinel }
                Mock Test-RsRestItemDataSource { $true }

                Test-RsDataSourceConnection -DataSource '/Sales/DS' -ReportPortalUri 'https://target/reports'

                Should -Invoke New-RsMigrationRestSession -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports'
                }
            }
        }

        It 'threads the helper''s session into Test-RsRestItemDataSource via -WebSession' {
            InModuleScope RsMigration {
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession { return $sentinel }
                Mock Test-RsRestItemDataSource { $true }

                Test-RsDataSourceConnection -DataSource '/Sales/DS' -ReportPortalUri 'https://target/reports'

                # The SAME session instance the helper returned must reach the RS
                # cmdlet; an impl that calls the helper but discards the session fails.
                Should -Invoke Test-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    [object]::ReferenceEquals($WebSession, $sentinel)
                }
            }
        }
    }
}
