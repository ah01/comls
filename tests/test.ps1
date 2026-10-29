#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'build\comls.exe'
$fixture = Join-Path $root 'build\comls_fixture.exe'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Cli([string]$Path, [string[]]$Arguments = @(), [string]$Scenario = 'error') {
    $start = [System.Diagnostics.ProcessStartInfo]::new($Path)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardErrorEncoding = $utf8
    $start.Environment['COMLS_TEST_SCENARIO'] = $Scenario
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [System.IO.MemoryStream]::new()
    try {
        Assert-True ($process.Start()) 'Failed to start CLI.'
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw 'CLI did not exit within 30 seconds.'
        }
        $null = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $bytes = $memory.ToArray()
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and
            $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Unexpected UTF-8 BOM.'
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $utf8.GetString($bytes)
            Stderr = $stderr
        }
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$header = Get-Content -LiteralPath (Join-Path $root 'src\ports.h') -Raw
$match = [regex]::Match($header, '#define COMLS_VERSION L"([^"]+)"')
Assert-True $match.Success 'Version definition was not found.'
$version = $match.Groups[1].Value
foreach ($binary in @($exe, $fixture)) {
    $result = Invoke-Cli $binary @('--version')
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq "comls $version`n" -and
        $result.Stderr -eq '') 'Version output or exit code is incorrect.'
    foreach ($flag in @('--help', '-h')) {
        $result = Invoke-Cli $binary @($flag)
        Assert-True ($result.ExitCode -eq 0 -and $result.Stdout.Contains('--version') -and
            $result.Stderr -eq '') 'Help output is incorrect or triggered discovery.'
    }
    foreach ($arguments in @(@('--bad'), @('COM1'), @('--version', '--bad'))) {
        $result = Invoke-Cli $binary $arguments
        Assert-True ($result.ExitCode -eq 2 -and $result.Stdout -eq '' -and
            $result.Stderr.Contains('Invalid argument')) 'Invalid arguments were not rejected.'
    }
}

$result = Invoke-Cli $fixture @() 'empty'
Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq "No COM ports found.`n" -and
    $result.Stderr -eq '') 'Empty enumeration output is incorrect.'
$result = Invoke-Cli $fixture @() 'error'
Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
    $result.Stderr.Contains('Synthetic discovery failure')) 'Discovery errors were hidden.'
$result = Invoke-Cli $fixture @() 'output-error'
Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
    $result.Stderr.Contains('Writing standard output')) 'Output errors were hidden.'
$result = Invoke-Cli $fixture @() 'unicode'
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -match '(?s)COM2\s+Unknown.*COM10\s+USB') 'Table sorting or transport is incorrect.'
$unicode = "USB serial $([char]0x017d)lu$([char]0x0165)ou$([char]0x010d)k$([char]0x00fd) $([char]0x65e5)$([char]0x672c) $([char]::ConvertFromUtf32(0x1f600))"
Assert-True ($result.Stdout.Contains($unicode)) 'Unicode was corrupted in redirected output.'
Assert-True (-not $result.Stdout.Contains([char]0xfffd)) 'A clipped surrogate pair corrupted table output.'
Assert-True (-not $result.Stdout.Contains('Instance ID')) 'Default output is unexpectedly verbose.'
foreach ($flag in @('--verbose', '-v')) {
    $result = Invoke-Cli $fixture @($flag) 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.Contains('0403:6001') -and
        $result.Stdout -match 'USB interface\s+02' -and
        $result.Stdout.Contains('Instance ID') -and
        $result.Stdout.Contains("1234567890123456789012345$([char]::ConvertFromUtf32(0x1f600))") -and
        $result.Stdout.Contains('Example manufacturer with a long full name') -and
        $result.Stdout.Contains($unicode)) 'Verbose metadata is incomplete.'
}
foreach ($arguments in @(@(), @('--verbose'), @('-v'))) {
    $result = Invoke-Cli $exe $arguments
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        ($result.Stdout.StartsWith('PORT') -or $result.Stdout -ceq "No COM ports found.`n")) `
        "Real device enumeration failed: $($result.Stderr)"
}
Write-Host 'CLI smoke tests passed (including synthetic empty, error, and Unicode devices).'
