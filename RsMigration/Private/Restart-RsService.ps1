function Restart-RsService {
    <#
    .SYNOPSIS
        Thin seam over the Windows-only Restart-Service so callers stay mockable.
    .DESCRIPTION
        Restart-Service does not exist on non-Windows hosts, so it cannot be
        mocked on the macOS/Linux quality gate. Routing the restart through this
        wrapper lets tests Mock Restart-RsService instead. The single statement
        below is intentionally the only code here - it cannot execute on the gate
        and therefore stays uncovered, so it is kept to one line.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private one-line seam over Restart-Service; ShouldProcess is handled by the public caller (Set-RsMigrationDatabase).')]
    [CmdletBinding()]
    param([string]$Name)
    Restart-Service -Name $Name
}
