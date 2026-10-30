#requires -Version 7.0
[CmdletBinding()]
param([switch]$Test)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Install Visual Studio Build Tools with Desktop development with C++ and the Windows SDK.'
}
$installation = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) {
    throw 'MSVC x64 was not found. Install Desktop development with C++ and the Windows SDK.'
}
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "MSVC environment setup was not found: $vcvars"
}

$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$flags = '/nologo /std:c17 /W4 /WX /utf-8 /O1 /GL /Gy /Gw /MT /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /D_WIN32_WINNT=0x0A00 /Isrc'
$link = '/link /LTCG /OPT:REF /OPT:ICF /INCREMENTAL:NO /DYNAMICBASE /NXCOMPAT'
$libraries = 'setupapi.lib cfgmgr32.lib advapi32.lib'
$commands = @(
    "call `"$vcvars`" >nul"
    'cd /d "' + $PSScriptRoot + '"'
    "cl $flags /Fobuild\ /Febuild\comls.exe src\comls.c src\ports.c src\win_ports.c src\output.c $link $libraries"
)
if ($Test) {
    $commands += "cl $flags /Fobuild\ /Febuild\test_ports.exe tests\test_ports.c src\ports.c $link"
    $commands += "cl $flags /Fobuild\ /Febuild\test_output.exe tests\test_output.c src\output.c $link"
    $commands += "cl $flags /Fobuild\ /Febuild\comls_fixture.exe src\comls.c src\ports.c src\output.c tests\fixture.c $link"
}
& $env:ComSpec /d /s /c ($commands -join ' && ')
if ($LASTEXITCODE -ne 0) {
    throw "MSVC build failed (exit code $LASTEXITCODE)."
}
$exe = Get-Item -LiteralPath (Join-Path $build 'comls.exe')
Write-Host "Built $($exe.FullName) ($($exe.Length) bytes)"
if ($Test) {
    foreach ($testExecutable in @('test_ports.exe', 'test_output.exe')) {
        & (Join-Path $build $testExecutable)
        if ($LASTEXITCODE -ne 0) {
            throw "$testExecutable failed (exit code $LASTEXITCODE)."
        }
    }
    & (Join-Path $PSScriptRoot 'tests\test.ps1')
}
