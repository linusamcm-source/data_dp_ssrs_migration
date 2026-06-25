function Export-RsMigrationInventory {
    <#
    .SYNOPSIS
        Inventories catalog data sources and pushes stored-credential secrets to
        Azure Key Vault (impl-doc 7.1 / runbook A1).
    .DESCRIPTION
        Enumerates every catalog item under -RsFolder via Get-RsRestFolderContent
        (recursively), reads each item's data sources via Get-RsRestItemDataSource,
        and emits one structured inventory record per data source containing the
        item path, data-source name, CredentialRetrieval mode, and connection string.

        For each data source whose CredentialRetrieval is 'Store' (stored
        credentials), the connection string is pushed to Key Vault via
        Set-AzKeyVaultSecret under a deterministic secret name derived from the
        item path + data-source name. Data sources that do not use 'Store' are
        still returned in the inventory but are NOT written to Key Vault.
    .PARAMETER VaultName
        Azure Key Vault name that stored-credential secrets are pushed to.
    .PARAMETER ReportPortalUri
        Base URI of the Reporting Services / PBIRS portal (REST v2.0 endpoint).
    .PARAMETER RsFolder
        Root catalog folder to enumerate from. Defaults to '/' (the whole catalog).
    .EXAMPLE
        Export-RsMigrationInventory -VaultName rsVault -ReportPortalUri https://target/reports
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Set-AzKeyVaultSecret requires a SecureString; the inventoried connection string must be wrapped to push it as a secret.')]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$ReportPortalUri,

        [string]$RsFolder = '/'
    )

    $items = Get-RsRestFolderContent -RsFolder $RsFolder -Recurse -ReportPortalUri $ReportPortalUri

    foreach ($item in $items) {
        $dataSources = Get-RsRestItemDataSource -RsItem $item.Path -ReportPortalUri $ReportPortalUri

        foreach ($ds in $dataSources) {
            $record = [pscustomobject]@{
                ItemPath            = $item.Path
                DataSourceName      = $ds.Name
                CredentialRetrieval = $ds.CredentialRetrieval
                ConnectionString    = $ds.ConnectString
            }

            if ($ds.CredentialRetrieval -eq 'Store') {
                # Push the STORED PASSWORD (CredentialsInServer.Password) -- the
                # symmetric-key-protected secret at risk per impl-doc section 9 --
                # mirroring the Python inventory, NOT the connection string. When a
                # Store data source carries no stored password there is nothing to
                # push, so the Key Vault write is skipped (the record is still
                # emitted), exactly like the Python contract.
                $password = $null
                $serverProp = $ds.PSObject.Properties['CredentialsInServer']
                if ($null -ne $serverProp -and $null -ne $serverProp.Value) {
                    $passwordProp = $serverProp.Value.PSObject.Properties['Password']
                    if ($null -ne $passwordProp) {
                        $password = $passwordProp.Value
                    }
                }
                if (-not [string]::IsNullOrEmpty($password)) {
                    $secretName = Get-RsMigrationSecretName -ItemPath $item.Path -DataSourceName $ds.Name
                    $secretValue = ConvertTo-SecureString -String ([string]$password) -AsPlainText -Force
                    Set-AzKeyVaultSecret -VaultName $VaultName -Name $secretName -SecretValue $secretValue | Out-Null
                }
            }

            $record
        }
    }
}

function Get-RsMigrationSecretName {
    <#
    .SYNOPSIS
        Derives a deterministic Azure Key Vault secret name from a catalog item
        path and a data-source name.
    .DESCRIPTION
        Key Vault secret names are limited to alphanumerics and dashes, so the
        item path + data-source name are joined and every run of non-alphanumeric
        characters (slashes, spaces, etc.) is collapsed to a single dash, with
        leading/trailing dashes trimmed, producing a human-readable stem.

        Because that sanitisation is lossy (e.g. '/Sales/Orders' and
        '/Sales-Orders' both collapse to 'Sales-Orders'), a short
        collision-resistant suffix - the first 8 hex characters of the SHA256
        of the UNSANITISED raw string - is appended so distinct items never
        collide and Set-AzKeyVaultSecret never silently overwrites another
        credential. The mapping is pure, so the same inputs always yield the
        same secret name, and the result stays within Key Vault's 127-char
        limit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath,

        [Parameter(Mandatory)]
        [string]$DataSourceName
    )

    $raw = '{0}-{1}' -f $ItemPath, $DataSourceName

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    }
    finally {
        $sha256.Dispose()
    }
    $suffix = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })

    $stem = ($raw -replace '[^A-Za-z0-9]+', '-').Trim('-')
    # Reserve room for the '-<8 hex>' suffix within Key Vault's 127-char limit.
    $maxStem = 127 - 9
    if ($stem.Length -gt $maxStem) {
        $stem = $stem.Substring(0, $maxStem).Trim('-')
    }

    if ($stem) {
        return '{0}-{1}' -f $stem, $suffix
    }
    return $suffix
}
