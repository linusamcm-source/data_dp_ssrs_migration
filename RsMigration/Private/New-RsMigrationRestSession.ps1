function New-RsMigrationRestSession {
    <#
    .SYNOPSIS
        Opens a PBIRS REST session as the current Windows identity.
    .DESCRIPTION
        Wraps ReportingServicesTools' New-RsRestSession for the report portal at
        $ReportPortalUri. Supplying no credential makes New-RsRestSession default
        to the calling Windows user (integrated auth). The returned
        [Microsoft.PowerShell.Commands.WebRequestSession] is the session the
        render and data-source seams thread into the underlying RS cmdlets via
        -WebSession.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private wrapper over New-RsRestSession; opening a REST session is a read-oriented auth handshake with no destructive side effect, and ShouldProcess is owned by the public caller.')]
    [CmdletBinding()]
    [OutputType([Microsoft.PowerShell.Commands.WebRequestSession])]
    param(
        [Parameter(Mandatory)]
        [string]$ReportPortalUri
    )

    return New-RsRestSession -ReportPortalUri $ReportPortalUri
}
