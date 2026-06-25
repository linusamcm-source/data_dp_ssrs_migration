function Invoke-RsKeyMgmt {
    <#
    .SYNOPSIS
        Thin wrapper around the native rskeymgmt.exe so the Windows-only binary
        call is mockable on the macOS/Linux gate (Windows-only-command
        mockability seam). Body cannot execute off-Windows; kept minimal.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$ExePath,
        [string[]]$Arguments
    )
    & $ExePath @Arguments
    # Return the exit code so callers do not depend on the ambient
    # $LASTEXITCODE, which throws under Set-StrictMode if never set.
    return $LASTEXITCODE
}
