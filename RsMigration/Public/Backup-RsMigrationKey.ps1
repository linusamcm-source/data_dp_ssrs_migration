function Backup-RsMigrationKey {
    <#
    .SYNOPSIS
        Backs up the Reporting Services encryption key on the SOURCE host to a
        local .snk (impl-doc 7.2 / runbook A4).
    .DESCRIPTION
        Wraps Backup-RsEncryptionKey. The key password is supplied as a
        [SecureString] -KeyPassword (prompted interactively via
        Read-Host -AsSecureString when omitted) and the .snk is written to
        -KeyPath. The SOURCE connection params default to the PBIRS-first splat
        from Resolve-RsConnection but are overridable to target the SSRS source
        (e.g. -ReportServerInstance SSRS -ReportServerVersion SQLServer2019).
    .EXAMPLE
        Backup-RsMigrationKey -KeyPath C:\rs\ReportServer.snk `
            -ReportServerInstance SSRS -ReportServerVersion SQLServer2019
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$KeyPath,

        [SecureString]$KeyPassword,

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

    if (-not $KeyPassword) {
        $KeyPassword = Read-Host -Prompt 'Encryption key password' -AsSecureString
    }
    $password = [System.Net.NetworkCredential]::new('', $KeyPassword).Password

    Backup-RsEncryptionKey @splat -Password $password -KeyPath $KeyPath -ErrorAction Stop
}
