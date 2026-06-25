@{
    # Run the default rule set, with the explicit exclusions justified below.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # FunctionsToExport is intentionally the wildcard '*'. The .psm1
        # auto-exports every Public/*.ps1 basename at import time, so wrapper
        # stories can drop a new Public script with no manifest edit. Listing
        # the functions explicitly would defeat that contract, so this rule
        # (which insists on an explicit export array) is deliberately suppressed.
        'PSUseToExportFieldsInManifest'
    )
}
