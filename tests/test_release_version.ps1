#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\release-version.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}

$work = Join-Path $PSScriptRoot "..\build\release_version_tests_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
try {
    Invoke-VersionGit $work @('init', '--quiet', '--initial-branch=main') | Out-Null
    Invoke-VersionGit $work @('config', 'user.name', 'Release test') | Out-Null
    Invoke-VersionGit $work @('config', 'user.email', 'release-test@example.invalid') | Out-Null
    Invoke-VersionGit $work @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-VersionGit $work @('config', 'tag.gpgsign', 'false') | Out-Null
    Invoke-VersionGit $work @('config', 'core.autocrlf', 'false') | Out-Null
    $header = Join-Path $work 'src\ports.h'
    [System.IO.File]::WriteAllText($header, "#define COMLS_VERSION L`"0.1.0`"`n")
    Invoke-VersionGit $work @('add', '.') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '-m', 'Initial') | Out-Null
    $rootCommit = Invoke-VersionGit $work @('rev-parse', 'HEAD')
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '0.1.1') 'Root must count without a baseline.'
    Invoke-VersionGit $work @('tag', '-a', 'v0.1.0', '-m', 'Baseline') | Out-Null
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '0.1.0') 'Baseline itself must have patch zero.'
    Invoke-VersionGit $work @('checkout', '--quiet', '-b', 'feature') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '--allow-empty', '-m', 'Feature one') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '--allow-empty', '-m', 'Feature two') | Out-Null
    $feature = Invoke-VersionGit $work @('rev-parse', 'HEAD')
    Invoke-VersionGit $work @('checkout', '--quiet', 'main') | Out-Null
    Invoke-VersionGit $work @('merge', '--quiet', '--no-ff', 'feature', '-m', 'Merge feature') | Out-Null
    $merged = Invoke-VersionGit $work @('rev-parse', 'HEAD')
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '0.1.1') 'Merge must count once.'
    Invoke-VersionGit $work @('commit', '--quiet', '--allow-empty', '-m', 'Next') | Out-Null
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '0.1.2') 'Baseline must be excluded.'
    Assert-True ((Get-ReleaseVersion $work $merged).Version -ceq '0.1.1') 'Explicit commit must not use HEAD.'
    Invoke-VersionGit $work @('tag', '--delete', 'v0.1.0') | Out-Null
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '0.1.3') 'No-baseline count must exclude side branches.'
    Invoke-VersionGit $work @('tag', 'v0.1.0', $feature) | Out-Null
    Assert-Rejected { Get-ReleaseVersion $work } 'Side-branch baseline must be rejected.'
    Invoke-VersionGit $work @('tag', '--delete', 'v0.1.0') | Out-Null
    [System.IO.File]::WriteAllText($header, "#define COMLS_VERSION L`"1.2.99`"`n")
    Invoke-VersionGit $work @('add', '.') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '-m', 'New series') | Out-Null
    Assert-True ((Get-ReleaseVersion $work).Version -ceq '1.2.4') 'X/Y must come from the selected source.'
    Assert-True ((Get-ReleaseVersion $work $rootCommit).Version -ceq '0.1.1') 'Old commit must use its own source.'
    Invoke-VersionGit $work @('tag', 'v1.2.0') | Out-Null
    Invoke-VersionGit $work @('tag', 'v0.1.0') | Out-Null
    Assert-Rejected { Get-ReleaseVersion $work $merged } 'Future baseline must be rejected.'
    [System.IO.File]::WriteAllText($header, "#define COMLS_VERSION L`"01.2.0`"`n")
    Invoke-VersionGit $work @('add', '.') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '-m', 'Invalid version') | Out-Null
    Assert-Rejected { Get-ReleaseVersion $work } 'Malformed source version must fail.'
    [System.IO.File]::WriteAllText((Join-Path $work '.git\shallow'),
        (Invoke-VersionGit $work @('rev-parse', 'HEAD')) + "`n")
    Assert-Rejected { Get-ReleaseVersion $work } 'Shallow history must fail.'
    Write-Host 'Release version tests passed.'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
