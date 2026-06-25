function New-RsMigrationBlobCredential {
    <#
    .SYNOPSIS
        Creates the SQL CREDENTIAL used for native BACKUP/RESTORE TO URL, picking
        one of three blob-auth models (impl-doc section 4 table).
    .DESCRIPTION
        Wraps New-DbaCredential. The credential shape depends on -Model:

          SAS             -> -Identity 'SHARED ACCESS SIGNATURE', SAS in -SecurePassword
          StorageKey      -> -Identity <containerUrl>,            access key in -SecurePassword
          ManagedIdentity -> -Identity 'Managed Identity',        no -SecurePassword

        The credential -Name is the container URL in every model (SQL matches the
        credential to a backup URL by name/prefix - impl-doc section 4 "Rules").
    .PARAMETER SqlInstance
        The SQL Server instance on which to create the credential.
    .PARAMETER ContainerUrl
        The blob container URL. Used as the credential name (and, for the
        StorageKey model, as the -Identity).
    .PARAMETER Model
        Blob-auth model: SAS (default), StorageKey, or ManagedIdentity.
    .PARAMETER SecurePassword
        The SAS token (SAS model) or storage access key (StorageKey model) as a
        SecureString. Not used for ManagedIdentity.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Thin wrapper; the state change and its -Force confirmation gate are owned by the underlying New-DbaCredential call.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$ContainerUrl,

        [ValidateSet('SAS', 'StorageKey', 'ManagedIdentity')]
        [string]$Model = 'SAS',

        [System.Security.SecureString]$SecurePassword
    )

    $params = @{
        SqlInstance = $SqlInstance
        Name        = $ContainerUrl
        Force       = $true
    }

    switch ($Model) {
        'SAS' {
            if (-not $SecurePassword) { throw "The SAS model requires -SecurePassword (the SAS token)." }
            $params.Identity = 'SHARED ACCESS SIGNATURE'
            $params.SecurePassword = $SecurePassword
        }
        'StorageKey' {
            if (-not $SecurePassword) { throw "The StorageKey model requires -SecurePassword (the storage access key)." }
            $params.Identity = $ContainerUrl
            $params.SecurePassword = $SecurePassword
        }
        'ManagedIdentity' {
            $params.Identity = 'Managed Identity'
            # No SecurePassword for managed identity.
        }
    }

    # dbatools swallows errors as warnings by default; -EnableException makes a
    # credential-creation failure terminating.
    New-DbaCredential @params -EnableException
}
