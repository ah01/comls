#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\bucket\comls.json') |
    ConvertFrom-Json
if ($manifest.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw 'Scoop manifest must specify a release version.'
}
if (@($manifest.architecture.PSObject.Properties).Count -ne 1 -or
    -not $manifest.architecture.PSObject.Properties['64bit']) {
    throw 'Scoop manifest must support only the x64 release.'
}
$release = $manifest.architecture.'64bit'
$base = "https://github.com/ah01/comls/releases/download/v$($manifest.version)"
$expectedUrls = @("$base/comls.exe", "$base/LICENSE")
if (@($release.url).Count -ne $expectedUrls.Count -or @($release.hash).Count -ne $expectedUrls.Count) {
    throw 'Scoop manifest must include the executable and license with hashes.'
}
for ($i = 0; $i -lt $expectedUrls.Count; $i++) {
    if ($release.url[$i] -cne $expectedUrls[$i] -or $release.hash[$i] -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Scoop release URL or SHA-256 hash is invalid.'
    }
}
if ($manifest.bin -cne 'comls.exe' -or $manifest.license -cne 'MIT, BSD-3-Clause') {
    throw 'Scoop manifest must expose comls and identify its bundled licenses.'
}
Write-Host 'Scoop manifest tests passed.'
