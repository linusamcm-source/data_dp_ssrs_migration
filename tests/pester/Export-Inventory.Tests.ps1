#Requires -Modules Pester

param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Export-RsMigrationInventory' {

    # AC1: enumerates catalog items via Get-RsRestFolderContent (recursively) and calls
    #      Get-RsRestItemDataSource once per item.
    It 'enumerates items via Get-RsRestFolderContent and reads data sources once per item' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
                [pscustomobject]@{ Path = '/Sales/Exec'; Type = 'PowerBIReport' }
                [pscustomobject]@{ Path = '/Sales/Summary'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{
                    Name                = 'DS1'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Data Source=db1;Initial Catalog=sales'
                }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            Should -Invoke Get-RsRestFolderContent -Times 1 -Exactly -ParameterFilter { $Recurse }
            Should -Invoke Get-RsRestItemDataSource -Times 3 -Exactly
        }
    }

    # AC1 (per-item targeting): each item's path is forwarded to Get-RsRestItemDataSource.
    It 'forwards each item path to Get-RsRestItemDataSource' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'DS1'; CredentialRetrieval = 'None'; ConnectString = 'cs' }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            Should -Invoke Get-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                $RsItem -eq '/Sales/Orders'
            }
        }
    }

    # AC2: for each Store data source, Set-AzKeyVaultSecret is called with a deterministic
    #      name derived from the item path + data-source name.
    It 'pushes a Store data source secret to Key Vault with a deterministic name' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{
                    Name                = 'WarehouseDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Data Source=wh;Initial Catalog=dw'
                }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            # Deterministic name = path + data-source name, sanitised to a Key Vault secret name
            # (alphanumeric + dashes only): '/Sales/Orders' + 'WarehouseDS' -> 'Sales-Orders-WarehouseDS'.
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq 'rsVault' -and $Name -eq 'Sales-Orders-WarehouseDS'
            }
        }
    }

    # AC2: the deterministic name is stable across runs for the same path + data-source name.
    It 'derives the same secret name deterministically for the same item path and data source' {
        InModuleScope RsMigration {
            $names = [System.Collections.Generic.List[string]]::new()
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Finance/Q1'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'LedgerDS'; CredentialRetrieval = 'Store'; ConnectString = 'cs' }
            }
            Mock Set-AzKeyVaultSecret { $names.Add($Name) }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'
            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            $names.Count | Should -Be 2
            $names[0] | Should -Be $names[1]
            $names[0] | Should -Be 'Finance-Q1-LedgerDS'
        }
    }

    # AC3: returns a structured inventory record per data source with item path,
    #      data-source name, CredentialRetrieval, and connection string.
    It 'returns a structured record per data source with path, name, retrieval mode and connection string' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
                [pscustomobject]@{ Path = '/Sales/Exec'; Type = 'PowerBIReport' }
            }
            Mock Get-RsRestItemDataSource {
                param($RsItem)
                if ($RsItem -eq '/Sales/Orders') {
                    [pscustomobject]@{ Name = 'OrdersDS'; CredentialRetrieval = 'Store'; ConnectString = 'cs-orders' }
                }
                else {
                    [pscustomobject]@{ Name = 'ExecDS'; CredentialRetrieval = 'Integrated'; ConnectString = 'cs-exec' }
                }
            }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 2

            $orders = $records | Where-Object { $_.DataSourceName -eq 'OrdersDS' }
            $orders.ItemPath | Should -Be '/Sales/Orders'
            $orders.CredentialRetrieval | Should -Be 'Store'
            $orders.ConnectionString | Should -Be 'cs-orders'

            $exec = $records | Where-Object { $_.DataSourceName -eq 'ExecDS' }
            $exec.ItemPath | Should -Be '/Sales/Exec'
            $exec.CredentialRetrieval | Should -Be 'Integrated'
            $exec.ConnectionString | Should -Be 'cs-exec'
        }
    }

    # AC3: an item with multiple data sources yields one record per data source.
    It 'returns one record per data source when an item has several' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Multi/Report'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'DsA'; CredentialRetrieval = 'Store'; ConnectString = 'a' }
                [pscustomobject]@{ Name = 'DsB'; CredentialRetrieval = 'Prompt'; ConnectString = 'b' }
            }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 2
            ($records | Where-Object DataSourceName -EQ 'DsA').ItemPath | Should -Be '/Multi/Report'
            ($records | Where-Object DataSourceName -EQ 'DsB').ItemPath | Should -Be '/Multi/Report'
        }
    }

    # AC4: a non-Store data source IS included in the returned inventory but produces NO
    #      Set-AzKeyVaultSecret call.
    It 'includes a non-Store data source in the inventory but does not write it to Key Vault' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Exec'; Type = 'PowerBIReport' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'IntegratedDS'; CredentialRetrieval = 'Integrated'; ConnectString = 'cs' }
            }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 1
            $records[0].CredentialRetrieval | Should -Be 'Integrated'

            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }
    }

    # AC2 + AC4 mixed: only the Store data sources are pushed; non-Store ones are skipped.
    It 'pushes only the Store data sources to Key Vault in a mixed set' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Mixed/One'; Type = 'Report' }
                [pscustomobject]@{ Path = '/Mixed/Two'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                param($RsItem)
                if ($RsItem -eq '/Mixed/One') {
                    [pscustomobject]@{ Name = 'StoreDS'; CredentialRetrieval = 'Store'; ConnectString = 'cs1' }
                }
                else {
                    [pscustomobject]@{ Name = 'NoneDS'; CredentialRetrieval = 'None'; ConnectString = 'cs2' }
                }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Mixed-One-StoreDS'
            }
        }
    }

    # An item with no data sources contributes no records and no Key Vault calls.
    It 'contributes no records for an item that has no data sources' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Empty/Item'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource { }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 0
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }
    }
}
