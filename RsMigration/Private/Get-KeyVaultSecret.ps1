function Get-KeyVaultSecret {
    <#
    .SYNOPSIS
        Retrieves a secret from Azure Key Vault as plaintext, or as raw bytes.
    .DESCRIPTION
        Wraps Get-AzKeyVaultSecret. By default returns the secret's plaintext
        string value. With -AsBytes, the secret text is treated as base64 and
        decoded to a [byte[]] - used to round-trip the encryption-key .snk that
        was stored base64-encoded (impl-doc sections 7.2/7.6).
    #>
    [CmdletBinding()]
    [OutputType([string], [byte[]])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$AsBytes
    )

    $plain = Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -AsPlainText

    if ($AsBytes) {
        return [System.Convert]::FromBase64String($plain)
    }

    return $plain
}
