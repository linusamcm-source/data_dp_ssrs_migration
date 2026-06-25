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
    #      name derived from the item path + data-source name, pushing the STORED PASSWORD
    #      (CredentialsInServer.Password) -- the same material the Python inventory pushes
    #      (impl-doc section 9) -- NOT the connection string.
    It 'pushes the stored password (not the connection string) to Key Vault under a deterministic name' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{
                    Name                = 'WarehouseDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Data Source=wh;Initial Catalog=dw'
                    CredentialsInServer = [pscustomobject]@{ UserName = 'dom\svc'; Password = 'wh-p@ss' }
                }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            # Deterministic name = sanitised path + data-source stem plus an
            # 8-hex SHA256 suffix of the raw string (collision resistance):
            # '/Sales/Orders' + 'WarehouseDS' -> 'Sales-Orders-WarehouseDS-eff4439e'.
            # The pushed SecureString must decode to the stored PASSWORD, never the ConnectString.
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $plain = [System.Net.NetworkCredential]::new('', $SecretValue).Password
                $VaultName -eq 'rsVault' -and
                $Name -eq 'Sales-Orders-WarehouseDS-eff4439e' -and
                $plain -eq 'wh-p@ss'
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
                [pscustomobject]@{
                    Name                = 'LedgerDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'cs'
                    CredentialsInServer = [pscustomobject]@{ UserName = 'dom\svc'; Password = 'ledger-pw' }
                }
            }
            Mock Set-AzKeyVaultSecret { $names.Add($Name) }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'
            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            $names.Count | Should -Be 2
            $names[0] | Should -Be $names[1]
            $names[0] | Should -Be 'Finance-Q1-LedgerDS-7a311fa9'
        }
    }

    # Collision resistance: two distinct inputs that sanitise to the same stem
    # ('/Sales/Orders'+'DS' and '/Sales-Orders'+'DS' both -> 'Sales-Orders-DS')
    # must yield DIFFERENT secret names so Set-AzKeyVaultSecret cannot silently
    # overwrite one credential with another. The name is also deterministic.
    It 'gives distinct secret names to inputs that collide after sanitising and stays deterministic' {
        InModuleScope RsMigration {
            $a1 = Get-RsMigrationSecretName -ItemPath '/Sales/Orders' -DataSourceName 'DS'
            $a2 = Get-RsMigrationSecretName -ItemPath '/Sales/Orders' -DataSourceName 'DS'
            $b = Get-RsMigrationSecretName -ItemPath '/Sales-Orders' -DataSourceName 'DS'

            # Deterministic: same input -> same name.
            $a1 | Should -Be $a2
            # Collision-resistant: distinct raw inputs -> distinct names.
            $a1 | Should -Not -Be $b
            # Still Key-Vault-legal (alphanumerics + dashes only).
            $a1 | Should -Match '^[A-Za-z0-9-]+$'
            $b | Should -Match '^[A-Za-z0-9-]+$'
        }
    }

    # Bounds + fallback: a very long input is truncated to stay within Key
    # Vault's 127-char limit, and an input with no alphanumerics still yields a
    # legal (hash-only) name.
    It 'keeps the secret name Key-Vault-legal and bounded for long and empty stems' {
        InModuleScope RsMigration {
            $long = Get-RsMigrationSecretName -ItemPath ('/A' * 200) -DataSourceName ('B' * 200)
            $long.Length | Should -BeLessOrEqual 127
            $long | Should -Match '^[A-Za-z0-9-]+$'

            # '/' + '/' sanitises to an empty stem, so only the hash suffix remains.
            $empty = Get-RsMigrationSecretName -ItemPath '/' -DataSourceName '/'
            $empty | Should -Match '^[A-Za-z0-9]+$'
            $empty.Length | Should -Be 8
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
                    [pscustomobject]@{
                        Name                = 'StoreDS'
                        CredentialRetrieval = 'Store'
                        ConnectString       = 'cs1'
                        CredentialsInServer = [pscustomobject]@{ UserName = 'dom\svc'; Password = 'mixed-pw' }
                    }
                }
                else {
                    [pscustomobject]@{ Name = 'NoneDS'; CredentialRetrieval = 'None'; ConnectString = 'cs2' }
                }
            }
            Mock Set-AzKeyVaultSecret { }

            Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Mixed-One-StoreDS-25827a22'
            }
        }
    }

    # H3 (cross-stack parity): a Store data source with NO stored password is still
    # inventoried, but nothing is pushed to Key Vault (nothing to push) -- mirroring
    # the Python inventory, which skips set_secret when CredentialsInServer.Password is absent.
    It 'records a Store data source with no stored password but does not write it to Key Vault' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                # Store mode but no CredentialsInServer / Password to push.
                [pscustomobject]@{ Name = 'EmptyStoreDS'; CredentialRetrieval = 'Store'; ConnectString = 'cs-empty' }
            }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 1
            $records[0].CredentialRetrieval | Should -Be 'Store'
            # The record still carries the connection string (Story 7 AC3).
            $records[0].ConnectionString | Should -Be 'cs-empty'
            # No password -> no Key Vault write.
            Should -Invoke Set-AzKeyVaultSecret -Times 0 -Exactly
        }
    }

    # H3: the returned record keeps the connection string even when the PASSWORD is
    # what gets pushed to Key Vault (the two are distinct: record = ConnectString,
    # vault payload = CredentialsInServer.Password).
    It 'keeps the connection string in the record while pushing the password to the vault' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{
                    Name                = 'OrdersDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Data Source=sql1;Initial Catalog=Sales'
                    CredentialsInServer = [pscustomobject]@{ UserName = 'dom\svc'; Password = 'orders-pw' }
                }
            }
            Mock Set-AzKeyVaultSecret { }

            $records = Export-RsMigrationInventory -VaultName 'rsVault' -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 1
            $records[0].ConnectionString | Should -Be 'Data Source=sql1;Initial Catalog=Sales'

            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $plain = [System.Net.NetworkCredential]::new('', $SecretValue).Password
                $plain -eq 'orders-pw'
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
