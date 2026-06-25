function Set-RsMigrationDataSource {
    <#
    .SYNOPSIS
        Re-keys a catalog item's data sources over the PBIRS REST v2.0 API
        (impl-doc section 8). Used in post-migration credential fixes and the
        lost-key re-key path.
    .DESCRIPTION
        Reads the item's current data sources via Get-RsRestItemDataSource
        (get-then-set), validates the credential preconditions the underlying
        Set-RsRestItemDataSource enforces, then writes them back.

        The HTTP verb is type-dependent and is driven by -RsItemType, which is
        forwarded verbatim to Set-RsRestItemDataSource: 'Report'/'DataSet' make
        the underlying cmdlet issue a PUT, 'PowerBIReport' makes it issue a
        PATCH (Set-RsRestItemDataSource exposes no explicit -Method parameter;
        the verb is derived from the item type inside that cmdlet). The wrapper
        also computes the same verb itself and returns it (.Method) alongside
        the JSON-array body it serialized (.BodyJson) so callers can confirm
        what was driven.

        Validation mirrors Set-RsRestItemDataSource / impl-doc section 8:
          - CredentialRetrieval='Store' (canonical capitalised casing, compared
            case-insensitively, shared with Story 13) requires CredentialsInServer.
          - A DataModelDataSource requires AuthType; AuthTypes other than 'Key'
            additionally require Username and Secret; 'Key' requires only Secret.
    .PARAMETER RsItem
        Catalog item path whose data sources are re-keyed.
    .PARAMETER RsItemType
        Item type: Report or DataSet (PUT) or PowerBIReport (PATCH).
    .PARAMETER ReportPortalUri
        Optional Report Portal URL forwarded to the REST cmdlets.
    .PARAMETER Credential
        Optional credentials forwarded to the REST cmdlets.
    .PARAMETER WebSession
        Optional REST web session forwarded to the REST cmdlets.
    .OUTPUTS
        A PSCustomObject with RsItem, RsItemType, Method (PUT/PATCH) and
        BodyJson (the JSON array sent to the server).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RsItem,

        [Parameter(Mandatory)]
        [ValidateSet('Report', 'DataSet', 'PowerBIReport')]
        [string]$RsItemType,

        [string]$ReportPortalUri,

        [System.Management.Automation.PSCredential]$Credential,

        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    # Forward only the connection params the caller actually supplied.
    $connection = @{}
    foreach ($p in 'ReportPortalUri', 'Credential', 'WebSession') {
        if ($PSBoundParameters.ContainsKey($p)) {
            $connection[$p] = $PSBoundParameters[$p]
        }
    }

    # --- GET first (get-then-set) ---------------------------------------------
    $dataSources = @(Get-RsRestItemDataSource -RsItem $RsItem @connection)

    # --- Validate each data source's credential preconditions -----------------
    foreach ($ds in $dataSources) {
        $modelProp = $ds.PSObject.Properties['DataModelDataSource']
        if ($null -ne $modelProp -and $null -ne $modelProp.Value) {
            $model = $modelProp.Value
            $authType = $model.PSObject.Properties['AuthType'].Value
            if ([string]::IsNullOrEmpty($authType)) {
                throw "DataModelDataSource.AuthType must be specified for '$RsItem'."
            }

            $secret = $model.PSObject.Properties['Secret'].Value
            if ($authType -ieq 'Key') {
                # Key auth needs only Secret.
                if ([string]::IsNullOrEmpty($secret)) {
                    throw "DataModelDataSource.Secret must be specified for AuthType 'Key' on '$RsItem'."
                }
            }
            else {
                # Windows / UsernamePassword / Impersonate need Username + Secret.
                $username = $model.PSObject.Properties['Username'].Value
                if ([string]::IsNullOrEmpty($username) -or [string]::IsNullOrEmpty($secret)) {
                    throw "DataModelDataSource.Username and Secret must be specified for AuthType '$authType' on '$RsItem'."
                }
            }
        }

        $retrievalProp = $ds.PSObject.Properties['CredentialRetrieval']
        if ($null -ne $retrievalProp -and $retrievalProp.Value -ieq 'Store') {
            $serverProp = $ds.PSObject.Properties['CredentialsInServer']
            if ($null -eq $serverProp -or $null -eq $serverProp.Value) {
                throw "CredentialsInServer must be specified when CredentialRetrieval is 'Store' on '$RsItem'."
            }
        }
    }

    # --- Compute the type-dependent HTTP verb ---------------------------------
    # PUT for Report/DataSet, PATCH for PowerBIReport. This is the same verb
    # Set-RsRestItemDataSource derives internally from its item type, surfaced
    # here so the driven method is observable.
    $method = if ($RsItemType -eq 'PowerBIReport') { 'PATCH' } else { 'PUT' }

    # The underlying Set-RsRestItemDataSource only accepts 'Report' or
    # 'PowerBIReport' on its -RsItemType ValidateSet -- it cannot be called with
    # 'DataSet' even though its dead internal branch checks for it. A DataSet
    # is re-keyed with the same PUT semantics as a Report, so map DataSet ->
    # Report for the downstream call. The PUT/PATCH choice (the verb seam) is
    # driven by the value forwarded here.
    $downstreamType = if ($RsItemType -eq 'PowerBIReport') { 'PowerBIReport' } else { 'Report' }

    # --- Serialize the body as a JSON array -----------------------------------
    $bodyJson = ConvertTo-Json -InputObject @($dataSources) -Depth 3

    if ($PSCmdlet.ShouldProcess($RsItem, "Re-key data sources ($method)")) {
        Write-Verbose "Re-keying data sources for '$RsItem' via $method."
        Set-RsRestItemDataSource -RsItem $RsItem -RsItemType $downstreamType `
            -DataSources $dataSources @connection
    }

    [pscustomobject]@{
        RsItem     = $RsItem
        RsItemType = $RsItemType
        Method     = $method
        BodyJson   = $bodyJson
    }
}
