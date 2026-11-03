#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$VersionRepositoryPath = (Split-Path $PSScriptRoot -Parent),
    [string]$VersionCommit = 'HEAD'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-VersionGit {
    param([string]$RepositoryPath, [string[]]$Arguments)
    $result = & git -C $RepositoryPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit code $LASTEXITCODE)."
    }
    return $result
}

function Get-ReleaseVersion {
    param([string]$RepositoryPath, [string]$Commit = 'HEAD')
    if ((Invoke-VersionGit $RepositoryPath @('rev-parse', '--is-shallow-repository')) -ne 'false') {
        throw 'Release versioning requires complete Git history and tags.'
    }
    $sha = Invoke-VersionGit $RepositoryPath @('rev-parse', '--verify', "$Commit^{commit}")
    $header = (Invoke-VersionGit $RepositoryPath @('show', "${sha}:src/ports.h")) -join "`n"
    $match = [regex]::Match($header,
        '(?m)^#define COMLS_VERSION L"((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\.(?:0|[1-9][0-9]*)"\r?$')
    if (-not $match.Success) {
        throw 'COMLS_VERSION must be a numeric X.Y.Z version without leading zeros.'
    }
    $series = $match.Groups[1].Value
    $baselineTag = "v$series.0"
    $history = @(Invoke-VersionGit $RepositoryPath @('rev-list', '--first-parent', $sha))
    $tags = @(Invoke-VersionGit $RepositoryPath @('tag', '--list', $baselineTag))
    $patch = $history.Count
    if ($tags.Count -ne 0) {
        $baseline = Invoke-VersionGit $RepositoryPath @('rev-parse', '--verify', "$baselineTag^{commit}")
        $patch = [array]::IndexOf($history, $baseline)
        if ($patch -lt 0) {
            throw "$baselineTag must point to a commit on the target's first-parent history."
        }
    }
    [pscustomobject]@{
        Version = "$series.$patch"
        Tag = "v$series.$patch"
        Commit = $sha
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-ReleaseVersion $VersionRepositoryPath $VersionCommit
}
