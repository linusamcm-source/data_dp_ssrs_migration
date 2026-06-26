function Restore-RsMigrationKey {
    <#
    .SYNOPSIS
        Restores the Reporting Services encryption key on the TARGET host
        (impl-doc 7.6 / runbook B10), enforcing the local-restart path.
    .DESCRIPTION
        Wraps Restore-RsEncryptionKey for the PBIRS instance. The key password is
        supplied as a [SecureString] -KeyPassword (prompted interactively via
        Read-Host -AsSecureString when omitted) and the .snk is read from
        -KeyPath. The cmdlet is invoked WITHOUT -Credential so the simple local
        service-restart path is used; supplying a -Credential triggers the fragile
        remote stop/start path (impl-doc 7.6 / risk register), so this wrapper
        rejects it with a descriptive error and must be run locally on the target
        host.
    .EXAMPLE
        Restore-RsMigrationKey -KeyPath C:\rs\ReportServer.snk
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$KeyPath,

        [SecureString]$KeyPassword,

        [string]$ReportServerInstance = 'PBIRS',

        # Accepted only to reject it: the restore must run locally (no -Credential).
        [System.Management.Automation.PSCredential]$Credential
    )

    if ($PSBoundParameters.ContainsKey('Credential')) {
        throw 'Restore-RsMigrationKey must run locally on the target host without -Credential. ' +
        'Supplying -Credential forces the fragile remote service-restart path (impl-doc 7.6). ' +
        'Run this cmdlet on the PBIRS target host instead.'
    }

    if (-not $KeyPassword) {
        $KeyPassword = Read-Host -Prompt 'Encryption key password' -AsSecureString
    }
    $password = [System.Net.NetworkCredential]::new('', $KeyPassword).Password

    Restore-RsEncryptionKey -ReportServerInstance $ReportServerInstance `
        -Password $password -KeyPath $KeyPath -ErrorAction Stop
}
