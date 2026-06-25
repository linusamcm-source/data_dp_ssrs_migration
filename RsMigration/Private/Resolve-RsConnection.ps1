function Resolve-RsConnection {
    <#
    .SYNOPSIS
        Returns the PBIRS-first connection splat shared by the wrapper cmdlets.
    .DESCRIPTION
        Centralises the connection defaults documented in impl-doc section 13
        (ConnectionHost): ReportServerInstance='PBIRS',
        ReportServerVersion='PowerBIReportServer', ComputerName='localhost'.
        Each default is overridable via the matching parameter so a caller can
        target the SSRS source instead.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ReportServerInstance = 'PBIRS',
        [string]$ReportServerVersion = 'PowerBIReportServer',
        [string]$ComputerName = 'localhost'
    )

    return @{
        ReportServerInstance = $ReportServerInstance
        ReportServerVersion  = $ReportServerVersion
        ComputerName         = $ComputerName
    }
}
