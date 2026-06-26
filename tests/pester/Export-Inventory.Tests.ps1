#Requires -Modules Pester

param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'RsMigration'
    Import-Module (Join-Path $script:ModuleRoot 'RsMigration.psd1') -Force

    # Source artefact PS2 rewrites - used by the static source-contract assertions
    # below. After PS2 the cmdlet stops writing secrets, so "no Key Vault push"
    # can only be proven by grepping the source (a removed/absent cmdlet cannot be
    # mocked for Should -Invoke), exactly as PS1 proved its own decommission.
    $script:InventorySource = Join-Path $script:ModuleRoot 'Public' 'Export-RsMigrationInventory.ps1'
}

AfterAll {
    Remove-Module RsMigration -Force -ErrorAction SilentlyContinue
}

Describe 'Export-RsMigrationInventory parameter contract' {
    # AC1: the Key Vault push is decommissioned, so -VaultName is gone entirely.
    It 'no longer exposes the -VaultName parameter' {
        $keys = (Get-Command Export-RsMigrationInventory).Parameters.Keys
        $keys | Should -Not -Contain 'VaultName'
    }

    # The REST catalog walk still needs the portal URI (RsFolder stays optional);
    # REST access uses the RS cmdlets' default current-user credentials.
    It 'still exposes -ReportPortalUri and -RsFolder' {
        $keys = (Get-Command Export-RsMigrationInventory).Parameters.Keys
        $keys | Should -Contain 'ReportPortalUri'
        $keys | Should -Contain 'RsFolder'
    }
}

Describe 'Export-RsMigrationInventory' {

    # AC3: enumerates catalog items via Get-RsRestFolderContent (recursively) and reads
    #      each item's data sources once via Get-RsRestItemDataSource.
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

            Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            Should -Invoke Get-RsRestFolderContent -Times 1 -Exactly -ParameterFilter { $Recurse }
            Should -Invoke Get-RsRestItemDataSource -Times 3 -Exactly
        }
    }

    # AC3 (per-item targeting): each item's path is forwarded to Get-RsRestItemDataSource.
    It 'forwards each item path to Get-RsRestItemDataSource' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'DS1'; CredentialRetrieval = 'None'; ConnectString = 'cs' }
            }

            Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            Should -Invoke Get-RsRestItemDataSource -Times 1 -Exactly -ParameterFilter {
                $RsItem -eq '/Sales/Orders'
            }
        }
    }

    # AC3: emits one inventory REPORT record per data source carrying item path,
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

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

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

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 2
            ($records | Where-Object DataSourceName -EQ 'DsA').ItemPath | Should -Be '/Multi/Report'
            ($records | Where-Object DataSourceName -EQ 'DsB').ItemPath | Should -Be '/Multi/Report'
        }
    }

    # AC3 + AC4: a stored-credential data source is REPORTED (so the operator knows a
    #            credential must be re-entered out of band) but the cmdlet NEVER emits
    #            the password - no Password property and no plaintext leak in any field.
    It 'reports a stored-credential data source without ever emitting the password' {
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

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 1
            $record = @($records)[0]

            # The report carries the inventory fields the operator needs...
            $names = $record.PSObject.Properties.Name
            $names | Should -Contain 'ItemPath'
            $names | Should -Contain 'DataSourceName'
            $names | Should -Contain 'CredentialRetrieval'
            $record.CredentialRetrieval | Should -Be 'Store'

            # ...but never the secret: no Password property and no plaintext password
            # value anywhere in the emitted record.
            $names | Should -Not -Contain 'Password'
            $allValues = ($record.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join "`n"
            $allValues | Should -Not -Match ([regex]::Escape('wh-p@ss'))
        }
    }

    # AC4 (regression): connection strings can themselves embed credentials
    #      (Password=/Pwd=). Because the inventory report is persisted to a fileshare,
    #      such a secret would otherwise leak at rest, contradicting the "NEVER emits a
    #      password" guarantee. The credential token must be masked before emission while
    #      every non-credential key=value pair is preserved verbatim.
    It 'masks credentials embedded in the connection string while preserving non-secret pairs' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Orders'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{
                    Name                = 'PasswordDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Server=db;Database=Sales;User ID=svc;Password=SuperSecret123;'
                }
                [pscustomobject]@{
                    Name                = 'PwdDS'
                    CredentialRetrieval = 'Store'
                    ConnectString       = 'Server=db2;Database=Mktg;Uid=svc2;Pwd=SuperSecret123'
                }
            }

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 2

            $password = $records | Where-Object DataSourceName -EQ 'PasswordDS'
            $password.ConnectionString | Should -Not -Match ([regex]::Escape('SuperSecret123'))
            $password.ConnectionString | Should -Match 'Password=\*\*\*'
            $password.ConnectionString | Should -Match ([regex]::Escape('Server=db'))
            $password.ConnectionString | Should -Match ([regex]::Escape('Database=Sales'))
            $password.ConnectionString | Should -Match ([regex]::Escape('User ID=svc'))

            # The 'Pwd=' spelling is masked too, and its non-secret pairs survive.
            $pwdRecord = $records | Where-Object DataSourceName -EQ 'PwdDS'
            $pwdRecord.ConnectionString | Should -Not -Match ([regex]::Escape('SuperSecret123'))
            $pwdRecord.ConnectionString | Should -Match 'Pwd=\*\*\*'
            $pwdRecord.ConnectionString | Should -Match ([regex]::Escape('Server=db2'))
            $pwdRecord.ConnectionString | Should -Match ([regex]::Escape('Database=Mktg'))
        }
    }

    # AC3: a non-Store data source is included in the inventory report just like any other.
    It 'includes a non-Store data source in the inventory report' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Sales/Exec'; Type = 'PowerBIReport' }
            }
            Mock Get-RsRestItemDataSource {
                [pscustomobject]@{ Name = 'IntegratedDS'; CredentialRetrieval = 'Integrated'; ConnectString = 'cs' }
            }

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 1
            $records[0].CredentialRetrieval | Should -Be 'Integrated'
            $records[0].PSObject.Properties.Name | Should -Not -Contain 'Password'
        }
    }

    # An item with no data sources contributes no records.
    It 'contributes no records for an item that has no data sources' {
        InModuleScope RsMigration {
            Mock Get-RsRestFolderContent {
                [pscustomobject]@{ Path = '/Empty/Item'; Type = 'Report' }
            }
            Mock Get-RsRestItemDataSource { }

            $records = Export-RsMigrationInventory -ReportPortalUri 'https://target/reports'

            @($records).Count | Should -Be 0
        }
    }
}

Describe 'Key Vault decommission (source contract)' {
    # AC2: the cmdlet references no Key Vault secret cmdlet - the stored-password
    #      push is gone, so re-entry of a stored credential is an out-of-band
    #      operator step (documented in the cmdlet help), not a vault write.
    It 'Export-RsMigrationInventory.ps1 references no Key Vault secret cmdlet' {
        $content = Get-Content -LiteralPath $script:InventorySource -Raw
        $content | Should -Not -Match 'Set-AzKeyVaultSecret'
        $content | Should -Not -Match 'Get-AzKeyVaultSecret'
    }

    # AC5: the now-orphaned secret-name helper (its sole caller was the deleted push)
    #      is removed. The helper name is assembled from fragments so this test file
    #      itself stays clear of the symbol - AC5's grep spans tests/pester/ as well
    #      as RsMigration/, and must return zero matches once PS2 lands.
    It 'no longer defines or calls the orphaned secret-name helper' {
        $helper = 'Get-RsMigration' + 'SecretName'
        $content = Get-Content -LiteralPath $script:InventorySource -Raw
        $content | Should -Not -Match $helper
    }
}
