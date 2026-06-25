function Reset-RsMigrationEncryptedContent {
    <#
    .SYNOPSIS
        Lost-key fallback: destroys all encrypted content on the local PBIRS
        instance via 'rskeymgmt.exe -d' (impl-doc section 7.8).
    .DESCRIPTION
        Used when the report-server encryption key/password is unrecoverable.
        Runs LOCALLY on the target. This permanently destroys every stored
        credential/connection string in the catalog, so it is a high-impact
        destructive operation guarded by SupportsShouldProcess /
        ConfirmImpact='High'. After running this, re-key every data source from
        the Key Vault inventory (Stories 8 / 13).

        The native rskeymgmt.exe call is routed through the internal
        Invoke-RsKeyMgmt helper (Windows-only-command mockability seam) so the
        destroy path is unit-testable off-Windows.
    .PARAMETER SqlMajorVersion
        The SQL Server Reporting Services major-version path segment (default
        'MSRS15') used to build the rskeymgmt.exe path. No filesystem existence
        check is performed; the path is constructed as a string only.
    .PARAMETER Force
        Skip the confirmation prompt and destroy encrypted content immediately.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [string]$SqlMajorVersion = 'MSRS15',

        [switch]$Force
    )

    $exePath = "C:\Program Files\Microsoft SQL Server\$SqlMajorVersion.PBIRS\Reporting Services\ReportServer\bin\rskeymgmt.exe"

    # -Force suppresses the confirmation prompt but must NOT defeat -WhatIf:
    # ShouldProcess still returns $false under -WhatIf (WhatIf wins over
    # ConfirmPreference), so a -WhatIf run never destroys, even with -Force.
    if ($Force) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($exePath, 'Destroy encrypted content (rskeymgmt.exe -d)')) {
        return
    }

    $exitCode = Invoke-RsKeyMgmt -ExePath $exePath -Arguments @('-d')

    if ($exitCode -ne 0) {
        throw "rskeymgmt.exe -d failed with exit code $exitCode."
    }
}
