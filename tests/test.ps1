#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'build\comls.exe'
$fixture = Join-Path $root 'build\comls_fixture.exe'
$noIds = Join-Path $root 'build\comls_no_ids.exe'
$badIds = Join-Path $root 'build\comls_bad_ids.exe'
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
$snapshot = [System.IO.File]::ReadAllText((Join-Path $root 'data\usb.ids'),
    [System.Text.Encoding]::Latin1)
$dateMatch = [regex]::Match($snapshot, '(?m)^# Date:\s*(\d{4}-\d{2}-\d{2}) ')
Assert-True $dateMatch.Success 'Upstream USB snapshot date was not found.'
$usbDate = $dateMatch.Groups[1].Value
foreach ($binary in @($exe, $fixture, $noIds, $badIds)) {
    $result = Invoke-Cli $binary @('--version')
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq "comls $version`nusb.ids $usbDate`n" -and
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
Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq "Found 0 ports:`n`n" -and
    $result.Stderr -eq '') 'Empty enumeration output is incorrect.'
$result = Invoke-Cli $fixture @() 'error'
Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
    $result.Stderr.Contains('Synthetic discovery failure')) 'Discovery errors were hidden.'
$result = Invoke-Cli $fixture @() 'output-error'
Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
    $result.Stderr.Contains('Writing standard output')) 'Output errors were hidden.'
$result = Invoke-Cli $fixture @() 'compact'
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -ceq "Found 2 ports (1 bluetooth, 1 USB):`n`nCOM1   (USB) USB Serial Port`nCOM10  (BL)  Bluetooth serial port`n") `
    'Compact output formatting, sorting, or transport is incorrect.'
$result = Invoke-Cli $fixture @() 'suffixes'
$expected = "Found 7 ports (7 USB):`n`nCOM1  (USB) Serial (COM2)`nCOM2  (USB) (COM2) Serial`n" +
    "COM3  (USB) Serial (COM3) extra`nCOM4  (USB) Serial`nCOM5  (USB) `n" +
    "COM6  (USB) Serial`nCOM7  (USB) Serial (COM77)`n"
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -ceq $expected) 'Compact description suffix handling is incorrect.'
$result = Invoke-Cli $fixture @() 'summary'
$expected = "Found 6 ports (1 native, 2 bluetooth, 1 USB, 1 virtual, 1 unknown):`n`n" +
    "COM3   (Native)  Unknown`nCOM5   (BL)      Unknown`nCOM7   (BL)      Unknown`n" +
    "COM11  (USB)     Unknown`nCOM12  (Virtual) Unknown`nCOM13  (Unknown) Unknown`n"
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -ceq $expected) 'Transport summary counts or spacing are incorrect.'
$result = Invoke-Cli $fixture @() 'single'
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -ceq "Found 1 port (1 native):`n`nCOM3  (Native) Unknown`n") `
    'Single-port summary is incorrect.'
$result = Invoke-Cli $fixture @() 'unicode'
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -match '(?s)^Found 2 ports \(1 USB, 1 unknown\):\n\nCOM2\s+\(Unknown\) Unknown\nCOM10\s+\(USB\)') `
    'Compact sorting, transport, or missing description is incorrect.'
$unicode = "USB serial $([char]0x017d)lu$([char]0x0165)ou$([char]0x010d)k$([char]0x00fd) $([char]0x65e5)$([char]0x672c) $([char]::ConvertFromUtf32(0x1f600))"
Assert-True ($result.Stdout.EndsWith("$unicode`n")) 'Unicode or suffix removal is incorrect in redirected output.'
Assert-True (-not $result.Stdout.Contains([char]0xfffd)) 'Unicode was corrupted in compact output.'
Assert-True (-not $result.Stdout.Contains('Instance ID')) 'Default output is unexpectedly verbose.'
Assert-True (-not $result.Stdout.Contains('manufacturer')) 'Default output unexpectedly includes manufacturers.'
foreach ($flag in @('--verbose', '-v')) {
    $result = Invoke-Cli $fixture @($flag) 'empty'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq "No COM ports found.`n") 'Verbose empty output changed.'
    $result = Invoke-Cli $fixture @($flag) 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith('PORT') -and
        -not $result.Stdout.Contains([char]0xfffd) -and
        $result.Stdout.Contains('0403:6001') -and
        $result.Stdout -match "USB vendor\s+Example USB vendor $([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))" -and
        $result.Stdout -match "USB product\s+Example USB product $([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))" -and
        $result.Stdout -match 'USB interface\s+02' -and
        $result.Stdout.Contains('Instance ID') -and
        $result.Stdout.Contains("1234567890123456789012345$([char]::ConvertFromUtf32(0x1f600))") -and
        $result.Stdout.Contains('Example manufacturer with a long full name') -and
        $result.Stdout.Contains("$unicode (COM10)")) 'Verbose metadata is incomplete.'
    $result = Invoke-Cli $fixture @($flag) 'compact'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith('PORT') -and $result.Stdout.Contains('Bluetooth') -and
        $result.Stdout.Contains('USB Serial Port (COM1)') -and
        $result.Stdout.Contains('Bluetooth serial port (COM10)')) `
        'Verbose transport names or table output changed.'
}
foreach ($case in @(
    @{ Scenario = 'usb-unknown'; Vendor = 'Unknown'; Product = 'Unknown' },
    @{ Scenario = 'usb-vendor-only'; Vendor = 'Vendor without products'; Product = 'Unknown' }
)) {
    $result = Invoke-Cli $fixture @('--verbose') $case.Scenario
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -match "USB vendor\s+$($case.Vendor)\n" -and
        $result.Stdout -match "USB product\s+$($case.Product)\n" -and
        $result.Stdout -match 'Manufacturer\s+Windows manufacturer\n' -and
        $result.Stdout -match 'Description\s+Windows description\n') `
        'Unknown USB IDs or Windows metadata were handled incorrectly.'
}
foreach ($binary in @($fixture, $noIds, $badIds)) {
    $result = Invoke-Cli $binary @('--verbose') 'bluetooth-usb'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.Contains('Bluetooth') -and $result.Stdout.Contains('0403:6001') -and
        -not $result.Stdout.Contains('USB vendor') -and -not $result.Stdout.Contains('USB product')) `
        'Bluetooth adapter incorrectly received USB database names or required the database.'
    $result = Invoke-Cli $binary @('--verbose') 'usb-no-ids'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        -not $result.Stdout.Contains('USB vendor')) 'Missing USB identity triggered a database lookup.'
    foreach ($scenario in @('empty', 'single')) {
        $result = Invoke-Cli $binary @('--verbose') $scenario
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') `
            'Verbose output without USB identities required the database.'
    }
    $result = Invoke-Cli $binary @() 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        -not $result.Stdout.Contains('USB vendor') -and -not $result.Stdout.Contains('USB product')) `
        'Compact output required or displayed database names.'
}
foreach ($binary in @($noIds, $badIds)) {
    $result = Invoke-Cli $binary @('--verbose') 'unicode'
    Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
        $result.Stderr.Contains('Loading embedded USB database')) `
        'Missing or corrupt USB resource was not reported before output.'
}
foreach ($arguments in @(@(), @('--verbose'), @('-v'))) {
    $result = Invoke-Cli $exe $arguments
    $prefix = if ($arguments.Count -eq 0) { '^Found [0-9]+ ports?( \([^\r\n]+\))?:\n\n' } else { '^PORT' }
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        ($result.Stdout -match $prefix -or $result.Stdout -ceq "No COM ports found.`n")) `
        "Real device enumeration failed: $($result.Stderr)"
}
$standalone = Join-Path $root "build\standalone-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $standalone -Force | Out-Null
$copiedExe = Join-Path $standalone 'comls.exe'
Copy-Item -LiteralPath $exe -Destination $copiedExe -Force
Push-Location $standalone
try {
    $result = Invoke-Cli $copiedExe @('--verbose')
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') `
        'Standalone copied executable failed without external database files.'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $copiedExe
    Remove-Item -LiteralPath $standalone
}
Write-Host 'CLI smoke tests passed (including USB enrichment, resource errors, and standalone execution).'
