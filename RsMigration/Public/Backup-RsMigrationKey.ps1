function Backup-RsMigrationKey {
    <#
    .SYNOPSIS
        Backs up the Reporting Services encryption key on the SOURCE host and
        pushes the resulting .snk to Azure Key Vault (impl-doc 7.2 / runbook A4).
    .DESCRIPTION
        Wraps Backup-RsEncryptionKey. The key password is read from Key Vault via
        the Private Get-KeyVaultSecret helper and the .snk is written to -KeyPath.
        The SOURCE connection params default to the PBIRS-first splat from
        Resolve-RsConnection but are overridable to target the SSRS source (e.g.
        -ReportServerInstance SSRS -ReportServerVersion SQLServer2019).

        Only after Backup-RsEncryptionKey succeeds are the .snk bytes read back,
        base64-encoded, and pushed to Key Vault via Set-AzKeyVaultSecret. If the
        backup throws, the error is re-thrown and nothing is written to Key Vault
        (no partial Key Vault write).
    .EXAMPLE
        Backup-RsMigrationKey -KeyPath C:\rs\ReportServer.snk -VaultName rsVault `
            -PasswordSecretName rsKeyPwd -SnkSecretName rsSnk `
            -ReportServerInstance SSRS -ReportServerVersion SQLServer2019
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PasswordSecretName',
        Justification = 'PasswordSecretName is a Key Vault secret *identifier*, not a password value.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Set-AzKeyVaultSecret requires a SecureString; the base64 .snk text must be wrapped to push it.')]
    param(
        [Parameter(Mandatory)]
        [string]$KeyPath,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$PasswordSecretName,

        [Parameter(Mandatory)]
        [string]$SnkSecretName,

        [string]$ReportServerInstance,

        [string]$ReportServerVersion,

        [string]$ComputerName
    )

    # PBIRS-first defaults, overridable to the SSRS source via the matching params.
    $conn = @{}
    if ($PSBoundParameters.ContainsKey('ReportServerInstance')) { $conn['ReportServerInstance'] = $ReportServerInstance }
    if ($PSBoundParameters.ContainsKey('ReportServerVersion')) { $conn['ReportServerVersion'] = $ReportServerVersion }
    if ($PSBoundParameters.ContainsKey('ComputerName')) { $conn['ComputerName'] = $ComputerName }
    $splat = Resolve-RsConnection @conn

    $password = Get-KeyVaultSecret -VaultName $VaultName -Name $PasswordSecretName

    # If this throws, the function rethrows and Set-AzKeyVaultSecret is never reached.
    Backup-RsEncryptionKey @splat -Password $password -KeyPath $KeyPath

    # Backup succeeded: read the .snk bytes and push them to Key Vault as base64.
    $bytes = [System.IO.File]::ReadAllBytes($KeyPath)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $secure = ConvertTo-SecureString -String $base64 -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $VaultName -Name $SnkSecretName -SecretValue $secure
}
