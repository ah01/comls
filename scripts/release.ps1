#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Publish', 'Promote')]
    [string]$Mode,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Tag,
    [string]$Commit,
    [string]$ExpectedVersion,
    [string]$RepositoryPath = (Split-Path $PSScriptRoot -Parent),
    [string]$ExecutablePath = (Join-Path $PSScriptRoot '..\build\comls.exe')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-version.ps1')
$releaseAssetNames = @('comls.exe', 'LICENSE', 'SHA256SUMS.txt')
$legacyReleaseAssetNames = @('comls.exe', 'LICENSE', 'usb.ids.LICENSE',
    'raspberrypi-usb-pid.LICENSE', 'SHA256SUMS.txt')

function Invoke-ReleaseGh {
    param([string[]]$Arguments)
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed (exit code $LASTEXITCODE)."
    }
    return $result
}

function Get-Release {
    param([string]$Repository, [string]$Tag)
    $pages = (Invoke-ReleaseGh @('api', '--paginate', '--slurp',
        "repos/$Repository/releases?per_page=100")) -join "`n" | ConvertFrom-Json
    $found = @($pages | ForEach-Object { $_ } | Where-Object { $_.tag_name -ceq $Tag })
    if ($found.Count -gt 1) { throw "Multiple releases found for $Tag." }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Get-ReleaseTagCommit {
    param([string]$Repository, [string]$Tag)
    $refs = (Invoke-ReleaseGh @('api', "repos/$Repository/git/matching-refs/tags/$Tag")) -join "`n" |
        ConvertFrom-Json
    $exact = @($refs | Where-Object { $_.ref -ceq "refs/tags/$Tag" })
    if ($exact.Count -eq 0) { return $null }
    return ((Invoke-ReleaseGh @('api', "repos/$Repository/commits/$Tag", '--jq', '.sha')) -join '').Trim()
}

function Assert-ReleaseAssets {
    param([string]$Directory)
    $names = @(Get-ChildItem -LiteralPath $Directory -File | Select-Object -ExpandProperty Name)
    if (@(Compare-Object $releaseAssetNames $names).Count -eq 0) {
        $expectedNames = $releaseAssetNames
    } elseif (@(Compare-Object $legacyReleaseAssetNames $names).Count -eq 0) {
        $expectedNames = $legacyReleaseAssetNames
    } else {
        throw 'Release must contain exactly the executable, combined license, and SHA256SUMS.txt.'
    }
    $lines = @(Get-Content -LiteralPath (Join-Path $Directory 'SHA256SUMS.txt'))
    $seen = @()
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^([0-9a-f]{64})  (comls\.exe|LICENSE|usb\.ids\.LICENSE|raspberrypi-usb-pid\.LICENSE)$')
        if (-not $match.Success -or $seen -contains $match.Groups[2].Value) {
            throw 'Invalid or duplicate checksum manifest entry.'
        }
        $name = $match.Groups[2].Value
        $hash = (Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256).Hash
        if ($hash -ine $match.Groups[1].Value) { throw "Checksum mismatch for $name." }
        $seen += $name
    }
    if ($seen.Count -ne $expectedNames.Count - 1) { throw 'Checksum manifest is incomplete.' }
}

function New-ReleaseAssets {
    param([string]$RepositoryPath, [string]$ExecutablePath, [string]$Directory)
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Copy-Item -LiteralPath $ExecutablePath -Destination (Join-Path $Directory 'comls.exe')
    $licensePaths = @(
        (Join-Path $RepositoryPath 'LICENSE'),
        (Join-Path $RepositoryPath 'data\usb.ids.LICENSE'),
        (Join-Path $RepositoryPath 'data\raspberrypi-usb-pid.LICENSE')
    )
    $licenseTexts = foreach ($path in $licensePaths) {
        [System.IO.File]::ReadAllText($path)
    }
    [System.IO.File]::WriteAllText((Join-Path $Directory 'LICENSE'), ($licenseTexts -join "`n`n"),
        [System.Text.UTF8Encoding]::new($false))
    $lines = foreach ($name in $releaseAssetNames | Where-Object { $_ -ne 'SHA256SUMS.txt' }) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [System.IO.File]::WriteAllText((Join-Path $Directory 'SHA256SUMS.txt'), ($lines -join "`n") + "`n",
        [System.Text.Encoding]::ASCII)
    Assert-ReleaseAssets $Directory
}

function Receive-ReleaseAssets {
    param([string]$Repository, [string]$Tag, [string]$Directory)
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Invoke-ReleaseGh @('release', 'download', $Tag, '--repo', $Repository, '--dir', $Directory) | Out-Null
}

function Assert-ReleaseExecutable {
    param([string]$ExecutablePath, [string]$Version)
    $output = @(& $ExecutablePath --version)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0 -or $output[0] -cne "comls $Version") {
        throw 'Executable version does not match the tested release version.'
    }
}

function Publish-AlphaRelease {
    param([string]$Repository, [string]$RepositoryPath, [string]$Commit,
        [string]$ExecutablePath, [string]$ExpectedVersion)
    $version = Get-ReleaseVersion $RepositoryPath $Commit
    if ($version.Version -cne $ExpectedVersion) { throw 'Version calculation changed since the tested build.' }
    Assert-ReleaseExecutable $ExecutablePath $ExpectedVersion
    $tag = $version.Tag
    $work = Join-Path $RepositoryPath "build\release_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $assets = Join-Path $work 'assets'
        New-ReleaseAssets $RepositoryPath $ExecutablePath $assets
        $tagCommit = Get-ReleaseTagCommit $Repository $tag
        if ($tagCommit -and $tagCommit -cne $version.Commit) {
            throw "$tag already identifies another commit; tags are never moved."
        }
        $release = Get-Release $Repository $tag
        if ($release -and -not $tagCommit) { throw "Existing release $tag has no corresponding tag." }
        if (-not $tagCommit) {
            Invoke-ReleaseGh @('api', "repos/$Repository/git/refs", '-f', "ref=refs/tags/$tag",
                '-f', "sha=$($version.Commit)") | Out-Null
        }
        if (-not $release) {
            $notes = @"
Alpha build of comls $($version.Version) for Windows 10/11 x64. Not a stable release.

Source commit: $($version.Commit)
Version: source X.Y plus the first-parent main commit count, excluding vX.Y.0 when present.
Download comls.exe and the combined LICENSE file. SHA256SUMS.txt contains SHA-256 checksums.
"@
            Invoke-ReleaseGh @('release', 'create', $tag, '--repo', $Repository, '--verify-tag',
                '--draft', '--prerelease', '--title', "comls $($version.Version) Alpha", '--notes', $notes) |
                Out-Null
            for ($attempt = 0; $attempt -lt 10 -and -not $release; $attempt++) {
                if ($attempt -gt 0) { Start-Sleep -Seconds 3 }
                $release = Get-Release $Repository $tag
            }
            if (-not $release) { throw "New draft $tag was not found." }
        }
        $existing = @($release.assets | ForEach-Object { $_.name })
        if ($existing.Count -gt 0) {
            $download = Join-Path $work 'existing'
            Receive-ReleaseAssets $Repository $tag $download
            $downloaded = @(Get-ChildItem -LiteralPath $download -File | Select-Object -ExpandProperty Name)
            if (@(Compare-Object $existing $downloaded).Count -ne 0) {
                throw 'Downloaded release asset list does not match the API response.'
            }
            foreach ($name in $existing) {
                if ($releaseAssetNames -cnotcontains $name -or
                    (Get-FileHash -LiteralPath (Join-Path $assets $name)).Hash -cne
                    (Get-FileHash -LiteralPath (Join-Path $download $name)).Hash) {
                    throw "Existing release asset conflicts with this build: $name. Nothing will be replaced."
                }
            }
        }
        $missing = @($releaseAssetNames | Where-Object { $existing -cnotcontains $_ })
        if (-not $release.draft) {
            if ($missing.Count -ne 0) { throw "Published release $tag has incomplete assets." }
            Write-Host "$tag is already published; preserving its assets and stability."
            return
        }
        foreach ($name in $missing) {
            Invoke-ReleaseGh @('release', 'upload', $tag, (Join-Path $assets $name), '--repo', $Repository) |
                Out-Null
        }
        $verified = Join-Path $work 'verified'
        Receive-ReleaseAssets $Repository $tag $verified
        Assert-ReleaseAssets $verified
        foreach ($name in $releaseAssetNames) {
            if ((Get-FileHash -LiteralPath (Join-Path $assets $name)).Hash -cne
                (Get-FileHash -LiteralPath (Join-Path $verified $name)).Hash) {
                throw "Uploaded asset differs from the tested build: $name."
            }
        }
        if ((Get-ReleaseTagCommit $Repository $tag) -cne $version.Commit) {
            throw "$tag changed during publication."
        }
        Invoke-ReleaseGh @('release', 'edit', $tag, '--repo', $Repository, '--draft=false',
            '--prerelease', '--latest=false') | Out-Null
        Write-Host "Published $tag as an Alpha prerelease."
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

function Promote-Release {
    param([string]$Repository, [string]$RepositoryPath, [string]$Tag)
    if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'Select an existing release tag in vX.Y.Z format.'
    }
    $sha = Invoke-VersionGit $RepositoryPath @('rev-parse', '--verify', "refs/tags/$Tag^{commit}")
    $main = @(Invoke-VersionGit $RepositoryPath @('rev-list', '--first-parent', 'refs/remotes/origin/main'))
    if ($main -cnotcontains $sha) { throw "$Tag is not on main's first-parent history." }
    if ((Get-ReleaseTagCommit $Repository $Tag) -cne $sha) {
        throw "Remote tag $Tag no longer matches the checked-out tag."
    }
    $version = Get-ReleaseVersion $RepositoryPath $sha
    if ($version.Tag -cne $Tag) { throw "$Tag does not match the source version and commit count." }
    $release = Get-Release $Repository $Tag
    if (-not $release -or $release.draft) { throw "$Tag must have an existing published release." }
    $work = Join-Path $RepositoryPath "build\promotion_$([guid]::NewGuid().ToString('N'))"
    try {
        Receive-ReleaseAssets $Repository $Tag $work
        Assert-ReleaseAssets $work
        Assert-ReleaseExecutable (Join-Path $work 'comls.exe') $version.Version
        if (-not $release.prerelease) {
            Write-Host "$Tag is already stable; leaving it unchanged."
            return
        }
        $notes = @"
Stable release of comls $($version.Version) for Windows 10/11 x64.

Source commit: $sha
Promoted from the tested Alpha prerelease without rebuilding or replacing assets.
Download comls.exe and the combined LICENSE file. SHA256SUMS.txt contains SHA-256 checksums.
"@
        Invoke-ReleaseGh @('release', 'edit', $Tag, '--repo', $Repository, '--prerelease=false',
            '--latest', '--title', "comls $($version.Version)", '--notes', $notes) | Out-Null
        Write-Host "Promoted $Tag to stable."
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Mode -or $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Specify a release mode and an owner/repository.'
    }
    if ($Mode -eq 'Publish') {
        if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Publishing requires the full tested commit SHA.' }
        Publish-AlphaRelease $Repository $RepositoryPath $Commit $ExecutablePath $ExpectedVersion
    } else {
        Promote-Release $Repository $RepositoryPath $Tag
    }
}
