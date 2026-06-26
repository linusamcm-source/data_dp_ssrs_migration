function Join-RsMigrationPath {
    <#
    .SYNOPSIS
        Joins an SMB share root and a file name into one backslash-delimited path,
        identically on every host OS.
    .DESCRIPTION
        The migration moves .bak files over SMB fileshares whose paths are always
        backslash-delimited, but the quality gate runs on macOS/Linux where
        Join-Path / [IO.Path] would emit forward slashes. This helper therefore
        builds the path by hand: it strips any trailing separators from the share
        and any leading separators from the file name, then joins the two with
        exactly one backslash, yielding the same string on every host.
    .PARAMETER Share
        The share root the file lives on. A trailing separator is ignored.
    .PARAMETER FileName
        The file name to append. A leading separator is ignored.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Share,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    $left = $Share.TrimEnd('\', '/')
    $right = $FileName.TrimStart('\', '/')
    return ('{0}\{1}' -f $left, $right)
}
