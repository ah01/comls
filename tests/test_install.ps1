#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$installer = Join-Path $PSScriptRoot '..\install.ps1'
$work = Join-Path $PSScriptRoot "..\build\install_tests_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
$savedEnvironment = @{}
foreach ($name in @('OS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'LOCALAPPDATA', 'Path')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$previousTls = [Net.ServicePointManager]::SecurityProtocol

function Invoke-RestMethod {
    param($Uri)
    Assert-True ($Uri -ceq 'https://api.github.com/repos/ah01/comls/releases?per_page=1') `
        'Installer must request the newest release, including prereleases.'
    if ($script:noRelease) { return @() }
    return [pscustomobject]@{
        tag_name = 'v0.1.1'
        draft = $false
        prerelease = $true
        assets = @('comls.exe', 'LICENSE', 'SHA256SUMS.txt') | Where-Object {
            $_ -ne $script:missingAsset
        } | ForEach-Object {
            [pscustomobject]@{ name = $_; browser_download_url = "https://example.invalid/$_" }
        }
    }
}

function Invoke-WebRequest {
    param([switch]$UseBasicParsing, $Uri, $OutFile)
    Assert-True $UseBasicParsing.IsPresent 'Downloads must support Windows PowerShell 5.1.'
    $script:temporaryDirectory = Split-Path $OutFile
    if ($script:downloadFailure) { throw 'Simulated network failure.' }
    $name = ($Uri -split '/')[-1]
    if ($name -eq 'SHA256SUMS.txt') {
        $lines = foreach ($asset in @('comls.exe', 'LICENSE')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path (Split-Path $OutFile) $asset)).Hash
            if ($script:badChecksum) { $hash = '0' * 64 }
            "$hash  $asset"
        }
        Set-Content -LiteralPath $OutFile -Value $lines
    } else {
        Set-Content -LiteralPath $OutFile -Value "Test $name"
    }
}

function Get-Item {
    param($LiteralPath)
    Assert-True ($LiteralPath -ceq 'HKCU:\Environment') 'Only the current user registry may be updated.'
    $key = [pscustomobject]@{}
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $Default, $Options)
        Assert-True ($Name -eq 'Path' -and $Options -eq 'DoNotExpandEnvironmentNames') `
            'Existing PATH entries must not be expanded.'
        return $script:userPath
    }
    return $key
}

function Set-ItemProperty {
    param($LiteralPath, $Name, $Value, $Type)
    Assert-True ($LiteralPath -ceq 'HKCU:\Environment' -and $Name -eq 'Path') `
        'Only the current user PATH may be updated.'
    Assert-True ($Type -eq 'ExpandString') 'User PATH must remain expandable.'
    $script:userPath = $Value
    $script:pathWrites++
}

try {
    $env:OS = 'Windows_NT'
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = ''
    $env:LOCALAPPDATA = Join-Path $work 'Local App Data'
    $env:Path = 'existing-session-path'
    $script:userPath = '%USERPROFILE%\bin;existing-user-path;'
    $script:pathWrites = 0
    $script:noRelease = $false
    $script:missingAsset = ''
    $script:badChecksum = $false
    $script:downloadFailure = $false
    $script:temporaryDirectory = ''
    $destination = Join-Path $env:LOCALAPPDATA 'Programs\comls'

    Get-Content -LiteralPath $installer -Raw | Invoke-Expression
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'comls.exe')) 'Executable must be installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'LICENSE')) 'License must be installed.'
    Assert-True ($script:userPath -ceq "%USERPROFILE%\bin;existing-user-path;$destination") `
        'Existing user PATH entries must be preserved.'
    Assert-True ($env:Path -ceq "existing-session-path;$destination") 'Current session must include comls.'
    Assert-True (-not (Test-Path -LiteralPath $script:temporaryDirectory)) 'Downloads must be cleaned up.'
    Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $previousTls) 'TLS settings must be restored.'

    Set-Content -LiteralPath (Join-Path $destination 'comls.exe') -Value 'Old version'
    . $installer
    Assert-True ($script:pathWrites -eq 1) 'Reinstallation must not duplicate user PATH entries.'
    Assert-True ($env:Path -ceq "existing-session-path;$destination") 'Session PATH must not be duplicated.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $destination 'comls.exe')) -eq 'Test comls.exe') `
        'Reinstallation must update the executable.'

    $script:userPath = $destination.ToUpperInvariant() + '\'
    $env:Path = $script:userPath
    . $installer
    Assert-True ($script:pathWrites -eq 1) 'PATH matching must ignore case and a trailing separator.'
    Assert-True ($env:Path -ceq $script:userPath) 'Equivalent session PATH entries must remain unchanged.'

    $script:userPath = ''
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
    . $installer
    Assert-True ($script:userPath -ceq $destination) 'An absent user PATH must be initialized.'

    foreach ($failure in @('noRelease', 'missingAsset', 'badChecksum', 'downloadFailure', 'unsupportedOS')) {
        Remove-Item -LiteralPath $destination -Recurse -Force
        $script:userPath = ''
        $script:pathWrites = 0
        Set-Variable -Name $failure -Scope Script -Value $true
        if ($failure -eq 'missingAsset') { $script:missingAsset = 'LICENSE' }
        if ($failure -eq 'unsupportedOS') { $env:OS = 'unsupported' }
        $rejected = $false
        try { . $installer } catch { $rejected = $true }
        Assert-True $rejected "$failure must stop installation."
        Assert-True (-not (Test-Path -LiteralPath $destination)) "$failure must not install files."
        Assert-True ($script:pathWrites -eq 0) "$failure must not change user PATH."
        Assert-True (-not (Test-Path -LiteralPath $script:temporaryDirectory)) "$failure must clean up downloads."
        Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $previousTls) "$failure must restore TLS."
        Set-Variable -Name $failure -Scope Script -Value $false
        $script:missingAsset = ''
        $env:OS = 'Windows_NT'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }
    Write-Host 'Installer tests passed.'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
