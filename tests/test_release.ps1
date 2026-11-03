#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\release.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}

function Assert-ReleaseExecutable {
    param([string]$ExecutablePath, [string]$Version)
    Assert-True ((Get-Content -LiteralPath $ExecutablePath -Raw) -ceq "comls $Version") `
        'Test executable has the wrong version.'
}

function Invoke-ReleaseGh {
    param([string[]]$Arguments)
    $script:calls.Add(($Arguments -join '|'))
    $operation = $Arguments[0..1] -join ' '
    if ($operation -eq 'api --paginate') {
        if ($null -eq $script:mockRelease) { return '[[]]' }
        return "[[$($script:mockRelease | ConvertTo-Json -Depth 10 -Compress)]]"
    }
    if ($operation -eq 'api repos/test/repo/git/matching-refs/tags/v0.1.1') {
        if ($null -eq $script:mockTag) { return '[]' }
        return '[{"ref":"refs/tags/v0.1.1"}]'
    }
    if ($operation -eq 'api repos/test/repo/commits/v0.1.1') { return $script:mockTag }
    if ($operation -eq 'api repos/test/repo/git/refs') {
        $script:mockTag = ($Arguments | Where-Object { $_ -like 'sha=*' }).Substring(4)
        return '{}'
    }
    if ($operation -eq 'release create') {
        Assert-True ($Arguments -contains '--draft' -and $Arguments -contains '--prerelease') `
            'New release must start as an Alpha draft.'
        $script:mockRelease = @{ tag_name = 'v0.1.1'; draft = $true; prerelease = $true; assets = @() }
        return
    }
    if ($operation -eq 'release upload') {
        if ($script:uploadsBeforeFailure -eq 0) { throw 'Simulated upload failure.' }
        $script:uploadsBeforeFailure--
        $path = $Arguments[3]
        $name = Split-Path $path -Leaf
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:remoteAssets $name))) `
            'Existing assets must never be overwritten.'
        Copy-Item -LiteralPath $path -Destination $script:remoteAssets
        $script:mockRelease.assets += @{ name = $name }
        return
    }
    if ($operation -eq 'release download') {
        $directory = $Arguments[[array]::IndexOf($Arguments, '--dir') + 1]
        Get-ChildItem -LiteralPath $script:remoteAssets -File | Copy-Item -Destination $directory
        return
    }
    if ($operation -eq 'release edit') {
        if ($Arguments -contains '--draft=false') {
            Assert-True ($Arguments -contains '--latest=false') 'Alpha must not become Latest.'
            $script:mockRelease.draft = $false
        }
        if ($Arguments -contains '--prerelease=false') {
            Assert-True ($Arguments -contains '--latest') 'Stable promotion must set Latest.'
            $script:mockRelease.prerelease = $false
        }
        return
    }
    throw "Unexpected gh invocation: $($Arguments -join ' ')"
}

$work = Join-Path $PSScriptRoot "..\build\release_tests_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
$script:remoteAssets = Join-Path $work 'remote-assets'
New-Item -ItemType Directory -Path $script:remoteAssets, (Join-Path $work 'data') | Out-Null
$script:mockRelease = $null
$script:mockTag = $null
$script:uploadsBeforeFailure = -1
$script:calls = [System.Collections.Generic.List[string]]::new()
try {
    Invoke-VersionGit $work @('init', '--quiet', '--initial-branch=main') | Out-Null
    Invoke-VersionGit $work @('config', 'user.name', 'Release test') | Out-Null
    Invoke-VersionGit $work @('config', 'user.email', 'release-test@example.invalid') | Out-Null
    Invoke-VersionGit $work @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-VersionGit $work @('config', 'tag.gpgsign', 'false') | Out-Null
    Invoke-VersionGit $work @('config', 'core.autocrlf', 'false') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $work 'src\ports.h'), "#define COMLS_VERSION L`"0.1.0`"`n")
    [System.IO.File]::WriteAllText((Join-Path $work 'LICENSE'), 'Application license')
    [System.IO.File]::WriteAllText((Join-Path $work 'data\usb.ids.LICENSE'), 'USB license')
    [System.IO.File]::WriteAllText((Join-Path $work 'data\raspberrypi-usb-pid.LICENSE'), 'Raspberry Pi license')
    $executable = Join-Path $work 'comls.exe'
    [System.IO.File]::WriteAllText($executable, 'comls 0.1.1')
    Invoke-VersionGit $work @('add', '.') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '-m', 'Initial') | Out-Null
    $sha = Invoke-VersionGit $work @('rev-parse', 'HEAD')
    Invoke-VersionGit $work @('update-ref', 'refs/remotes/origin/main', $sha) | Out-Null

    Assert-Rejected { Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.2' } `
        'Changed version must be rejected before publication.'
    Assert-True ($script:calls.Count -eq 0) 'Invalid version must not call GitHub.'
    $script:uploadsBeforeFailure = 2
    Assert-Rejected { Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1' } `
        'Upload errors must surface.'
    Assert-True ($script:mockRelease.draft) 'Failed upload must leave the release as a draft.'
    Assert-True ($script:mockRelease.assets.Count -eq 2) 'Test must exercise partial draft recovery.'
    $script:uploadsBeforeFailure = -1
    Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1'
    Assert-True (-not $script:mockRelease.draft -and $script:mockRelease.prerelease) `
        'Publication must produce a prerelease.'
    Assert-True ($script:mockTag -ceq $sha) 'Tag must identify the tested commit.'
    Assert-ReleaseAssets $script:remoteAssets
    $count = $script:calls.Count
    Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1'
    Assert-True (@($script:calls | Select-Object -Skip $count | Where-Object {
        $_ -like 'release upload*' -or $_ -like 'release edit*' -or $_ -like 'release create*'
    }).Count -eq 0) 'Rerunning publication must not mutate a published release.'
    [System.IO.File]::WriteAllText((Join-Path $script:remoteAssets 'comls.exe'), 'corrupt')
    Assert-Rejected { Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1' } `
        'Publication must reject conflicting assets.'
    Copy-Item -LiteralPath $executable -Destination $script:remoteAssets -Force
    $script:mockTag = 'a' * 40
    Assert-Rejected { Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1' } `
        'Publication must reject a tag pointing to a different commit.'
    $script:mockTag = $sha
    Invoke-VersionGit $work @('tag', 'v0.1.1', $sha) | Out-Null
    Assert-Rejected { Promote-Release 'test/repo' $work 'v0.1.1;invalid' } 'Invalid promotion tag must fail.'
    $script:mockRelease.draft = $true
    Assert-Rejected { Promote-Release 'test/repo' $work 'v0.1.1' } 'Draft promotion must fail.'
    $script:mockRelease.draft = $false
    [System.IO.File]::WriteAllText((Join-Path $script:remoteAssets 'comls.exe'), 'corrupt')
    Assert-Rejected { Promote-Release 'test/repo' $work 'v0.1.1' } 'Checksum failure must block promotion.'
    Copy-Item -LiteralPath $executable -Destination $script:remoteAssets -Force
    Promote-Release 'test/repo' $work 'v0.1.1'
    Assert-True (-not $script:mockRelease.prerelease) 'Promotion must clear prerelease.'
    $count = $script:calls.Count
    Promote-Release 'test/repo' $work 'v0.1.1'
    Publish-AlphaRelease 'test/repo' $work $sha $executable '0.1.1'
    Assert-True (-not $script:mockRelease.prerelease) 'Publication must not downgrade stable releases.'
    Assert-True (@($script:calls | Select-Object -Skip $count | Where-Object {
        $_ -like 'release edit*'
    }).Count -eq 0) 'Repeated promotion must not change Latest or release state.'
    Invoke-VersionGit $work @('checkout', '--quiet', '-b', 'unmerged') | Out-Null
    Invoke-VersionGit $work @('commit', '--quiet', '--allow-empty', '-m', 'Off-main') | Out-Null
    Invoke-VersionGit $work @('tag', 'v0.1.2') | Out-Null
    Assert-Rejected { Promote-Release 'test/repo' $work 'v0.1.2' } 'Off-main tag must not be promoted.'
    Write-Host 'Release publication and promotion tests passed (mock GitHub; no network writes).'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
