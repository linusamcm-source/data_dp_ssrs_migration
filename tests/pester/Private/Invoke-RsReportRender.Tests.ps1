#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-RsReportRender (Private seam)' {

    # Post-PS4 contract: the render seam must obtain its REST session from the
    # integrated-auth helper New-RsMigrationRestSession and thread that EXACT session
    # into Out-RsRestCatalogItem via -WebSession. Obtaining the session but then
    # discarding it (calling Out-RsRestCatalogItem without the helper's session) is a
    # failure, which the reference-equality filter below pins.

    Context 'AC3 routes the render through the integrated-auth session helper' {

        It 'obtains the session via New-RsMigrationRestSession (passing the portal URI)' {
            InModuleScope RsMigration {
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession { return $sentinel }
                Mock Out-RsRestCatalogItem { }

                Invoke-RsReportRender -RsItem '/Sales/Orders' -ReportPortalUri 'https://target/reports'

                Should -Invoke New-RsMigrationRestSession -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports'
                }
            }
        }

        It 'threads the helper''s session into Out-RsRestCatalogItem via -WebSession' {
            InModuleScope RsMigration {
                $sentinel = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Mock New-RsMigrationRestSession { return $sentinel }
                Mock Out-RsRestCatalogItem { }

                Invoke-RsReportRender -RsItem '/Sales/Orders' -ReportPortalUri 'https://target/reports'

                # The SAME session instance the helper returned must reach the RS
                # cmdlet; an impl that calls the helper but discards the session fails.
                Should -Invoke Out-RsRestCatalogItem -Times 1 -Exactly -ParameterFilter {
                    [object]::ReferenceEquals($WebSession, $sentinel)
                }
            }
        }
    }
}
