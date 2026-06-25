#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Set-RsMigrationDataSource' {

    # ---- AC1: get-then-set ordering ------------------------------------------
    Context 'AC1 reads current data sources before writing (get-then-set)' {

        It 'calls Get-RsRestItemDataSource before Set-RsRestItemDataSource' {
            InModuleScope RsMigration {
                $script:calls = [System.Collections.Generic.List[string]]::new()
                $ds = [pscustomobject]@{
                    CredentialRetrieval = 'Integrated'
                }
                Mock Get-RsRestItemDataSource {
                    $script:calls.Add('get')
                    return $ds
                }
                Mock Set-RsRestItemDataSource { $script:calls.Add('set') }

                Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                $script:calls[0] | Should -Be 'get'
                $script:calls[1] | Should -Be 'set'
                Should -Invoke Get-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $RsItem -eq '/Sales/Orders'
                }
            }
        }

        It 'forwards a supplied -ReportPortalUri to both the get and the set' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ CredentialRetrieval = 'Integrated' }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report `
                    -ReportPortalUri 'https://target/reports'

                Should -Invoke Get-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports'
                }
                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $ReportPortalUri -eq 'https://target/reports'
                }
            }
        }
    }

    # ---- AC2: type-dependent HTTP method -------------------------------------
    Context 'AC2 drives the type-dependent HTTP method' {

        It 'drives a PUT for a Report (Set-RsRestItemDataSource called with -RsItemType Report)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ CredentialRetrieval = 'Integrated' }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                # The wrapper's own method decision (the verb it intends to drive).
                $result.Method | Should -Be 'PUT'
                # The real seam: -RsItemType is what makes the underlying cmdlet issue a PUT.
                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $RsItemType -eq 'Report'
                }
            }
        }

        It 'drives a PUT for a DataSet (forwarded to the underlying cmdlet as a PUT-driving type)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ CredentialRetrieval = 'Integrated' }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/OrdersDataSet' -RsItemType DataSet

                # The wrapper's own verb decision for a DataSet is PUT.
                $result.Method | Should -Be 'PUT'
                # Set-RsRestItemDataSource's -RsItemType ValidateSet only accepts
                # Report/PowerBIReport, so a DataSet is forwarded as 'Report' (the
                # PUT-driving type) -- never as 'DataSet', which the cmdlet rejects.
                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $RsItemType -eq 'Report'
                }
            }
        }

        It 'drives a PATCH for a PowerBIReport (Set-RsRestItemDataSource called with -RsItemType PowerBIReport)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = 'Windows'
                        Username = 'dom\svc'
                        Secret   = 'p@ss'
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport

                $result.Method | Should -Be 'PATCH'
                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                    $RsItemType -eq 'PowerBIReport'
                }
            }
        }
    }

    # ---- AC3: body serialized as a JSON array --------------------------------
    Context 'AC3 serializes the body as a JSON array' {

        It 'produces a JSON array via ConvertTo-Json -Depth 3 (exposed on the result)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ CredentialRetrieval = 'Integrated' }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                # JSON array starts with '[' even for a single data source.
                $result.BodyJson.TrimStart() | Should -Match '^\['
                ($result.BodyJson | ConvertFrom-Json).Count | Should -Be 1
            }
        }

        It 'serializes a single data source as a one-element array (not a bare object)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ CredentialRetrieval = 'None' }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                $parsed = $result.BodyJson | ConvertFrom-Json
                # A bare object would not be enumerable to a single-element array.
                @($parsed).Count | Should -Be 1
                $result.BodyJson.TrimStart()[0] | Should -Be '['
            }
        }
    }

    # ---- H2: body always carries CredentialRetrieval (cross-stack parity) ----
    Context 'H2 guarantees CredentialRetrieval is in the body actually sent' {

        It 'injects CredentialRetrieval into the data source written when the GET result omits it' {
            InModuleScope RsMigration {
                # A GET result whose data source has NO CredentialRetrieval property.
                $ds = [pscustomobject]@{ Name = 'OrphanDS'; ConnectString = 'cs' }
                Mock Get-RsRestItemDataSource { return $ds }

                $script:sentDataSources = $null
                Mock Set-RsRestItemDataSource { $script:sentDataSources = @($DataSources) }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                # The objects ACTUALLY passed to the cmdlet must carry CredentialRetrieval.
                $sent = $script:sentDataSources[0]
                $sent.PSObject.Properties.Name | Should -Contain 'CredentialRetrieval'
                [string]::IsNullOrEmpty($sent.CredentialRetrieval) | Should -BeFalse

                # And the observability artifact reflects what was sent.
                $body = $result.BodyJson | ConvertFrom-Json
                @($body)[0].PSObject.Properties.Name | Should -Contain 'CredentialRetrieval'
                [string]::IsNullOrEmpty(@($body)[0].CredentialRetrieval) | Should -BeFalse
            }
        }

        It 'normalizes an empty CredentialRetrieval to a canonical value before writing' {
            InModuleScope RsMigration {
                # The property is present but empty -- still not a valid body value.
                $ds = [pscustomobject]@{ Name = 'EmptyRetrievalDS'; CredentialRetrieval = ''; ConnectString = 'cs' }
                Mock Get-RsRestItemDataSource { return $ds }

                $script:sentDataSources = $null
                Mock Set-RsRestItemDataSource { $script:sentDataSources = @($DataSources) }

                Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                [string]::IsNullOrEmpty($script:sentDataSources[0].CredentialRetrieval) | Should -BeFalse
            }
        }

        It 'preserves an existing CredentialRetrieval value rather than overwriting it' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{ Name = 'KeepDS'; CredentialRetrieval = 'Integrated'; ConnectString = 'cs' }
                Mock Get-RsRestItemDataSource { return $ds }

                $script:sentDataSources = $null
                Mock Set-RsRestItemDataSource { $script:sentDataSources = @($DataSources) }

                $result = Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report

                $script:sentDataSources[0].CredentialRetrieval | Should -Be 'Integrated'
                (@($result.BodyJson | ConvertFrom-Json)[0]).CredentialRetrieval | Should -Be 'Integrated'
            }
        }
    }

    # ---- AC4: Store without CredentialsInServer throws -----------------------
    Context 'AC4 validates Store credential-retrieval' {

        It 'throws when CredentialRetrieval=Store but CredentialsInServer is missing' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    CredentialRetrieval = 'Store'
                    CredentialsInServer = $null
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report } |
                    Should -Throw '*CredentialsInServer*'

                # Never reaches the write.
                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }

        It 'matches Store case-insensitively (lowercase store still requires CredentialsInServer)' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    CredentialRetrieval = 'store'
                    CredentialsInServer = $null
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report } |
                    Should -Throw '*CredentialsInServer*'

                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }

        It 'does NOT throw when Store has CredentialsInServer present' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    CredentialRetrieval = 'Store'
                    CredentialsInServer = [pscustomobject]@{ UserName = 'dom\svc'; Password = 'p@ss' }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Orders' -RsItemType Report } |
                    Should -Not -Throw

                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly
            }
        }
    }

    # ---- AC5: DataModelDataSource validation ---------------------------------
    Context 'AC5 validates a DataModelDataSource' {

        It 'throws when AuthType is missing' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = $null
                        Username = 'dom\svc'
                        Secret   = 'p@ss'
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport } |
                    Should -Throw '*AuthType*'

                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }

        It 'throws when Username is missing for a non-Key AuthType' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = 'Windows'
                        Username = $null
                        Secret   = 'p@ss'
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport } |
                    Should -Throw '*Username*'

                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }

        It 'throws when Secret is missing for a non-Key AuthType' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = 'UsernamePassword'
                        Username = 'sa'
                        Secret   = $null
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport } |
                    Should -Throw '*Secret*'

                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }

        It 'AuthType=Key requires only Secret (no Username) and does NOT throw' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = 'Key'
                        Username = $null
                        Secret   = 'aASDBsdas12?asd2+asdajkda='
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport } |
                    Should -Not -Throw

                Should -Invoke Set-RsRestItemDataSource -Times 1 -Exactly
            }
        }

        It 'AuthType=Key still throws when Secret is missing' {
            InModuleScope RsMigration {
                $ds = [pscustomobject]@{
                    DataSourceSubType   = 'DataModel'
                    DataModelDataSource = [pscustomobject]@{
                        AuthType = 'Key'
                        Username = $null
                        Secret   = $null
                    }
                }
                Mock Get-RsRestItemDataSource { return $ds }
                Mock Set-RsRestItemDataSource { }

                { Set-RsMigrationDataSource -RsItem '/Sales/Exec' -RsItemType PowerBIReport } |
                    Should -Throw '*Secret*'

                Should -Invoke Set-RsRestItemDataSource -Times 0 -Exactly
            }
        }
    }
}
