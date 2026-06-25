function Restore-RsMigrationKey {
    <#
    .SYNOPSIS
        Restores the Reporting Services encryption key on the TARGET host
        (impl-doc 7.6 / runbook B10), enforcing the local-restart path.
    .DESCRIPTION
        Wraps Restore-RsEncryptionKey for the PBIRS instance. The key password is
        read from Key Vault via the Private Get-KeyVaultSecret helper. The cmdlet
        is invoked WITHOUT -Credential so the simple local service-restart path is
        used; supplying a -Credential triggers the fragile remote stop/start path
        (impl-doc 7.6 / risk register), so this wrapper rejects it with a
        descriptive error and must be run locally on the target host.
    .EXAMPLE
        Restore-RsMigrationKey -KeyPath C:\rs\ReportServer.snk -VaultName rsVault `
            -PasswordSecretName rsKeyPwd
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PasswordSecretName',
        Justification = 'PasswordSecretName is a Key Vault secret *identifier*, not a password value.')]
    param(
        [Parameter(Mandatory)]
        [string]$KeyPath,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$PasswordSecretName,

        [string]$ReportServerInstance = 'PBIRS',

        # Accepted only to reject it: the restore must run locally (no -Credential).
        [System.Management.Automation.PSCredential]$Credential
    )

    if ($PSBoundParameters.ContainsKey('Credential')) {
        throw 'Restore-RsMigrationKey must run locally on the target host without -Credential. ' +
        'Supplying -Credential forces the fragile remote service-restart path (impl-doc 7.6). ' +
        'Run this cmdlet on the PBIRS target host instead.'
    }

    $password = Get-KeyVaultSecret -VaultName $VaultName -Name $PasswordSecretName

    Restore-RsEncryptionKey -ReportServerInstance $ReportServerInstance `
        -Password $password -KeyPath $KeyPath
}
