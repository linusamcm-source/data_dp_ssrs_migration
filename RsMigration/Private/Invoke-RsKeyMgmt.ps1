function Invoke-RsKeyMgmt {
    <#
    .SYNOPSIS
        Thin wrapper around the native rskeymgmt.exe so the Windows-only binary
        call is mockable on the macOS/Linux gate (Windows-only-command
        mockability seam). Body cannot execute off-Windows; kept minimal.
    #>
    [CmdletBinding()]
    param(
        [string]$ExePath,
        [string[]]$Arguments
    )
    & $ExePath @Arguments
}
