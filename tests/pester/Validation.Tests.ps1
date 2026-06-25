#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-RsMigrationValidation' {
    # AC1: render-tests each report item (mocked REST render endpoint) and
    #      records pass/fail per item.
    Context 'AC1 - render-tests each report item and records pass/fail per item' {
        It 'renders every report item and records a pass result per item' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }      # all renders succeed
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders', '/Sales/Exec') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                # One render per report item.
                Should -Invoke Invoke-RsReportRender -Times 2 -Exactly
                Should -Invoke Invoke-RsReportRender -Times 1 -Exactly -ParameterFilter {
                    $RsItem -eq '/Sales/Orders'
                }
                Should -Invoke Invoke-RsReportRender -Times 1 -Exactly -ParameterFilter {
                    $RsItem -eq '/Sales/Exec'
                }

                # Per-item pass/fail recording.
                $result.Reports.Count | Should -Be 2
                ($result.Reports | Where-Object { $_.RsItem -eq '/Sales/Orders' }).Success | Should -BeTrue
                ($result.Reports | Where-Object { $_.RsItem -eq '/Sales/Exec' }).Success | Should -BeTrue
            }
        }

        It 'records a fail result for a report item whose render throws' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender {
                    if ($RsItem -eq '/Sales/Broken') { throw 'render failed' }
                }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders', '/Sales/Broken') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                ($result.Reports | Where-Object { $_.RsItem -eq '/Sales/Orders' }).Success | Should -BeTrue
                ($result.Reports | Where-Object { $_.RsItem -eq '/Sales/Broken' }).Success | Should -BeFalse
            }
        }
    }

    # AC2: probes each data source via the internal Test-RsDataSourceConnection
    #      helper (mocked) once per data source and records per-source result.
    Context 'AC2 - probes each data source via Test-RsDataSourceConnection helper' {
        It 'invokes Test-RsDataSourceConnection once per data source and records each result' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection {
                    param($DataSource)
                    return ($DataSource -ne '/Sales/Bad')
                }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders') `
                    -DataSource @('/Sales/Good', '/Sales/Bad') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                # One probe per data source.
                Should -Invoke Test-RsDataSourceConnection -Times 2 -Exactly
                Should -Invoke Test-RsDataSourceConnection -Times 1 -Exactly -ParameterFilter {
                    $DataSource -eq '/Sales/Good'
                }
                Should -Invoke Test-RsDataSourceConnection -Times 1 -Exactly -ParameterFilter {
                    $DataSource -eq '/Sales/Bad'
                }

                # Per-source result recording.
                $result.DataSources.Count | Should -Be 2
                ($result.DataSources | Where-Object { $_.DataSource -eq '/Sales/Good' }).Connected | Should -BeTrue
                ($result.DataSources | Where-Object { $_.DataSource -eq '/Sales/Bad' }).Connected | Should -BeFalse
            }
        }
    }

    # AC3: queries msdb for auto-recreated SQL Agent subscription jobs via
    #      Invoke-DbaQuery (mocked) and records whether subscriptions are present.
    Context 'AC3 - queries msdb for auto-recreated SQL Agent subscription jobs' {
        It 'queries msdb via Invoke-DbaQuery and records subscriptions present when jobs exist' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'JobA' }, [pscustomobject]@{ name = 'JobB' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                Should -Invoke Invoke-DbaQuery -Times 1 -Exactly -ParameterFilter {
                    # -SqlInstance binds to DbaInstanceParameter[]; compare via its string form.
                    $Database -eq 'msdb' -and "$SqlInstance" -eq 'TARGETSQL'
                }
                $result.SubscriptionsPresent | Should -BeTrue
            }
        }

        It 'records subscriptions absent when the msdb query returns no jobs' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @() }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                $result.SubscriptionsPresent | Should -BeFalse
            }
        }
    }

    # AC4: Success is $false if any individual check failed, $true only when all pass.
    Context 'AC4 - Success aggregates every check' {
        It 'Success is $true when every render passes, every source connects, and subscriptions are present' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders', '/Sales/Exec') `
                    -DataSource @('/Sales/Orders', '/Sales/Exec') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                $result.Success | Should -BeTrue
            }
        }

        It 'Success is $false when a render fails' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender {
                    if ($RsItem -eq '/Sales/Exec') { throw 'render failed' }
                }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders', '/Sales/Exec') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                $result.Success | Should -BeFalse
            }
        }

        It 'Success is $false when a data source fails to connect' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection {
                    param($DataSource)
                    return ($DataSource -ne '/Sales/Bad')
                }
                Mock Invoke-DbaQuery { @([pscustomobject]@{ name = 'Job1' }) }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders') `
                    -DataSource @('/Sales/Good', '/Sales/Bad') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                $result.Success | Should -BeFalse
            }
        }

        It 'Success is $false when no subscription jobs are present' {
            InModuleScope RsMigration {
                Mock Invoke-RsReportRender { }
                Mock Test-RsDataSourceConnection { $true }
                Mock Invoke-DbaQuery { @() }

                $result = Invoke-RsMigrationValidation `
                    -ReportItem @('/Sales/Orders') `
                    -DataSource @('/Sales/Orders') `
                    -SqlInstance 'TARGETSQL' -Database 'msdb' `
                    -ReportPortalUri 'https://target/reports'

                $result.Success | Should -BeFalse
            }
        }
    }
}
