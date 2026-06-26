function Import-RsMigrationSubscription {
    <#
    .SYNOPSIS
        Recreates catalog subscriptions from a source portal onto a target portal
        over the PBIRS REST v2.0 API (selective, idempotent refresh).
    .DESCRIPTION
        The ReportingServicesTools subscription cmdlets (Get-/New-/Set-RsSubscription)
        are SOAP-only and have no -WebSession parameter, so they cannot consume the
        integrated-auth REST session PS4 mandates. Subscriptions are therefore moved
        with direct REST calls (Invoke-RestMethod -WebSession), one session per
        portal opened by New-RsMigrationRestSession - the helper's WebSession is the
        only thing that authenticates REST, so no explicit credential is wired here.

        It enumerates the source portal's subscriptions, optionally narrows them to
        an -IncludeSubscription allow-list (matched on Description, case-insensitively),
        then for each selected subscription either UPDATES an existing target
        content-match in place (PUT, addressed by the target's server-assigned Id) or
        CREATES it (POST). A source subscription is "already present" when a target
        subscription shares the tuple (Owner, Path, Description, EventType) - NOT Id,
        which the server reassigns on recreate - so a re-run refreshes rather than
        duplicates.

        Before serialising, each subscription is projected to a clean payload that
        strips server-managed / read-only fields (Id, Status, LastRunTime,
        ModifiedDate, ModifiedBy). On a PUT the payload Id is set to the existing
        TARGET id so the body and the URL key agree; on a POST no Id is sent and the
        server assigns one.

        An include name that matches no source subscription is reported with a
        non-terminating warning and surfaced on the returned summary's
        UnmatchedInclude, not treated as fatal.
    .PARAMETER SourceReportPortalUri
        Base URI of the source Reporting Services / PBIRS portal to read
        subscriptions from (REST v2.0 endpoint).
    .PARAMETER TargetReportPortalUri
        Base URI of the target portal the subscriptions are written to.
    .PARAMETER IncludeSubscription
        Optional allow-list of subscription Descriptions to import. Matching is
        case-insensitive and duplicate names (including case-variants) are collapsed.
        Empty or omitted imports every source subscription.
    .OUTPUTS
        A PSCustomObject summary with Created, Updated and UnmatchedInclude
        ([string[]] - the include names that matched nothing; empty when all
        matched).
    .NOTES
        Match-key uniqueness: the content key (Owner, report Path, Description,
        EventType) is NOT guaranteed unique on a portal. Two target subscriptions
        sharing that tuple cannot be disambiguated - one will overwrite the other on
        import - so a non-terminating warning is emitted when such a collision is
        detected while indexing the target. There is no further mitigation; resolve
        the collision (e.g. by giving the subscriptions distinct Descriptions) before
        relying on idempotent refresh.

        Field names: the PBIRS REST v2.0 Subscription field names used for the match
        key (Owner, Path = the report's catalog path, Description, EventType) are
        ASSUMED and not confirmed against a live portal; each is read tolerantly, so
        a renamed/missing field degrades to $null rather than throwing.

        Failure model: the cmdlet is FAIL-FAST - it aborts on the first REST error
        rather than continuing past it - but it is SAFE to re-run, because matching
        on the content tuple makes a re-run refresh existing subscriptions in place
        instead of duplicating them.
    .EXAMPLE
        Import-RsMigrationSubscription -SourceReportPortalUri https://source/reports `
            -TargetReportPortalUri https://target/reports -IncludeSubscription 'Daily sales'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceReportPortalUri,

        [Parameter(Mandatory)]
        [string]$TargetReportPortalUri,

        [string[]]$IncludeSubscription
    )

    # Tolerant property read: the v2.0 Subscription field names are assumed and may
    # differ on a real portal, so read through PSObject and degrade a missing field
    # to $null instead of hard-throwing under the module-wide Set-StrictMode.
    function Get-RsSubField {
        param($Subscription, [string]$Name)
        $prop = $Subscription.PSObject.Properties[$Name]
        if ($prop) { $prop.Value } else { $null }
    }

    # The idempotency content key (NOT Id, which the server reassigns on recreate).
    function Get-RsSubKey {
        param($Subscription)
        '{0}|{1}|{2}|{3}' -f `
        (Get-RsSubField $Subscription 'Owner'),
        (Get-RsSubField $Subscription 'Path'),
        (Get-RsSubField $Subscription 'Description'),
        (Get-RsSubField $Subscription 'EventType')
    }

    # Project a clean JSON payload: strip server-managed / read-only fields so a PUT
    # never re-asserts the SOURCE Id and a POST carries no Id at all. For a PUT the
    # caller passes the existing TARGET id so the body key matches the URL key.
    function ConvertTo-RsSubPayload {
        param($Subscription, [string]$TargetId)
        $serverManaged = @('Id', 'Status', 'LastRunTime', 'ModifiedDate', 'ModifiedBy')
        $clean = [ordered]@{}
        foreach ($prop in $Subscription.PSObject.Properties) {
            if ($serverManaged -notcontains $prop.Name) {
                $clean[$prop.Name] = $prop.Value
            }
        }
        if ($TargetId) { $clean['Id'] = $TargetId }
        $clean | ConvertTo-Json -Depth 10
    }

    # One integrated-auth REST session per portal; the WebSession is the sole
    # credential carried into every REST hop below.
    $sourceSession = New-RsMigrationRestSession -ReportPortalUri $SourceReportPortalUri
    $targetSession = New-RsMigrationRestSession -ReportPortalUri $TargetReportPortalUri

    # Enumerate both portals; the OData envelope's .value is the subscription array.
    $sourceSubs = @((Invoke-RestMethod -Method Get `
                -Uri "$SourceReportPortalUri/api/v2.0/Subscriptions" `
                -WebSession $sourceSession).value)
    $targetSubs = @((Invoke-RestMethod -Method Get `
                -Uri "$TargetReportPortalUri/api/v2.0/Subscriptions" `
                -WebSession $targetSession).value)

    # Allow-list filtering keys off Description; drop null/empty names and collapse
    # duplicates case-insensitively so a repeated name warns/collects only once.
    $includeNames = [System.Collections.Generic.List[string]]::new()
    $seenInclude = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($IncludeSubscription)) {
        if ($name -and $seenInclude.Add($name)) { $includeNames.Add($name) }
    }
    $unmatched = [System.Collections.Generic.List[string]]::new()

    if ($includeNames.Count -gt 0) {
        # -contains is case-insensitive, so the allow-list match is too.
        $selected = @($sourceSubs | Where-Object { $includeNames -contains (Get-RsSubField $_ 'Description') })

        # Report include names that matched no source subscription (non-fatal).
        $sourceDescriptions = @($sourceSubs | ForEach-Object { Get-RsSubField $_ 'Description' })
        foreach ($name in $includeNames) {
            if ($sourceDescriptions -notcontains $name) {
                Write-Warning "Include name '$name' matched no source subscription; skipping."
                $unmatched.Add($name)
            }
        }
    }
    else {
        $selected = @($sourceSubs)
    }

    # Index existing target subscriptions by content tuple so a re-run updates the
    # matching target (by its own Id) instead of creating a duplicate. The key is
    # not guaranteed unique; warn (non-terminating) on a collision - one will win.
    $targetIndex = @{}
    foreach ($t in $targetSubs) {
        $key = Get-RsSubKey $t
        if ($targetIndex.ContainsKey($key)) {
            $dupDesc = Get-RsSubField $t 'Description'
            Write-Warning "Target subscriptions collide on (Owner, Path, Description, EventType) for '$dupDesc'; the match key cannot disambiguate them and one will overwrite the other."
        }
        $targetIndex[$key] = $t
    }

    $created = 0
    $updated = 0
    foreach ($sub in $selected) {
        $key = Get-RsSubKey $sub
        $desc = Get-RsSubField $sub 'Description'

        if ($targetIndex.ContainsKey($key)) {
            $targetId = Get-RsSubField $targetIndex[$key] 'Id'
            $body = ConvertTo-RsSubPayload -Subscription $sub -TargetId $targetId
            if ($PSCmdlet.ShouldProcess($desc, 'Update subscription')) {
                $null = Invoke-RestMethod -Method Put `
                    -Uri "$TargetReportPortalUri/api/v2.0/Subscriptions($targetId)" `
                    -WebSession $targetSession -Body $body -ContentType 'application/json'
                $updated++
            }
        }
        else {
            $body = ConvertTo-RsSubPayload -Subscription $sub
            if ($PSCmdlet.ShouldProcess($desc, 'Create subscription')) {
                $null = Invoke-RestMethod -Method Post `
                    -Uri "$TargetReportPortalUri/api/v2.0/Subscriptions" `
                    -WebSession $targetSession -Body $body -ContentType 'application/json'
                $created++
            }
        }
    }

    [pscustomobject]@{
        Created           = $created
        Updated           = $updated
        UnmatchedInclude  = $unmatched.ToArray()
    }
}
