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
            $result.Stdout.Contains('--usb-only') -and
            $result.Stdout.Contains('-d') -and $result.Stdout.Contains('-vv') -and
            $result.Stderr -eq '') 'Help output is incorrect or triggered discovery.'
    }
    foreach ($arguments in @(@('--bad'), @('COM1'), @('--version', '--bad'), @('-u', '--bad'),
        @('-vvv'), @('-d', '--bad'), @('-vv', '--bad'))) {
        $result = Invoke-Cli $binary $arguments
        Assert-True ($result.ExitCode -eq 2 -and $result.Stdout -eq '' -and
            $result.Stderr.Contains('Invalid argument')) 'Invalid arguments were not rejected.'
    }
}

foreach ($flag in @('-u', '--usb-only')) {
    $result = Invoke-Cli $fixture @($flag) 'summary'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq "Found 1 port (1 USB):`n`nCOM11  (USB) Unknown`n") `
        'USB-only filtering or summary is incorrect.'
    $result = Invoke-Cli $fixture @($flag) 'compact'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq "Found 1 port (1 USB):`n`nCOM1  (USB) USB Serial Port`n") `
        'USB-only output retained Bluetooth ports or unfiltered column widths.'
    $result = Invoke-Cli $fixture @($flag) 'compact-details'
    $names = @([regex]::Matches($result.Stdout, '(?m)^COM\d+') | ForEach-Object { $_.Value })
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith("Found 9 ports (9 USB):`n`n") -and
        ($names -join ',') -ceq 'COM1,COM2,COM4,COM5,COM6,COM7,COM8,COM11,COM12') `
        'USB-only filtering lost ports or changed numeric ordering.'
    $result = Invoke-Cli $fixture @($flag) 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith("Found 1 port (1 USB):`n`nCOM10  (USB)") -and
        $result.Stdout.Contains('USB: Example USB vendor') -and
        $result.Stdout.Contains(' / Example USB product') -and
        -not $result.Stdout.Contains('COM2')) 'USB-only output lost USB metadata or retained unknown ports.'
    foreach ($verboseFlag in @('-v', '--verbose', '-d', '-vv')) {
        $result = Invoke-Cli $fixture @($verboseFlag, $flag) 'unicode'
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
            $result.Stdout.StartsWith("Found 1 port (1 USB):`n`nCOM10`n") -and
            $result.Stdout.Contains('USB vendor') -and -not $result.Stdout.Contains('COM2')) `
            'USB-only verbose output is incorrect.'
        Assert-True ($result.Stdout.Contains('USB VID:PID:') -eq ($verboseFlag -eq '-vv')) `
            'USB-only output did not respect VID/PID visibility for the detail level.'
    }
    foreach ($binary in @($fixture, $noIds, $badIds)) {
        foreach ($scenario in @('empty', 'single', 'bluetooth-usb')) {
            $result = Invoke-Cli $binary @($flag) $scenario
            Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
                $result.Stdout -ceq "Found 0 ports:`n`n") 'USB-only empty output is incorrect.'
            foreach ($detailFlag in @('-v', '-d', '-vv')) {
                $result = Invoke-Cli $binary @($flag, $detailFlag) $scenario
                Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
                    $result.Stdout -ceq "Found 0 ports:`n`n") 'USB-only verbose empty output is incorrect.'
            }
        }
        foreach ($infoFlag in @('--help', '--version')) {
            $result = Invoke-Cli $binary @($flag, $infoFlag)
            Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
                $result.Stdout.Length -gt 0) 'USB-only help/version triggered discovery.'
        }
    }
    $result = Invoke-Cli $fixture @($flag) 'error'
    Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
        $result.Stderr.Contains('Synthetic discovery failure')) 'USB-only filtering hid a discovery error.'
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
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') 'Compact Unicode output failed.'
$unicode = "USB serial $([char]0x017d)lu$([char]0x0165)ou$([char]0x010d)k$([char]0x00fd) $([char]0x65e5)$([char]0x672c) $([char]::ConvertFromUtf32(0x1f600))"
$usbUnicode = "$([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))"
$expected = "Found 2 ports (1 USB, 1 unknown):`n`n" +
    "COM2   (Unknown) Unknown [1234567890123456789012345$([char]::ConvertFromUtf32(0x1f600))]`n" +
    "COM10  (USB)     $unicode [Example manufacturer with a long full name, USB: Example USB vendor $usbUnicode / Example USB product $usbUnicode]`n"
Assert-True ($result.Stdout -ceq $expected) 'Compact metadata, Unicode, or suffix removal is incorrect.'
Assert-True (-not $result.Stdout.Contains([char]0xfffd)) 'Unicode was corrupted in compact output.'
Assert-True (-not $result.Stdout.Contains('Instance ID')) 'Default output is unexpectedly verbose.'
$result = Invoke-Cli $fixture @() 'compact-details'
$expected = "Found 12 ports (2 native, 1 bluetooth, 9 USB):`n`n" +
    "COM1   (USB)    Serial [Maker, USB: Vendor / Product]`n" +
    "COM2   (USB)    Serial [USB: Vendor / Product]`n" +
    "COM3   (Native) Serial`n" +
    "COM4   (USB)    Serial [USB: Vendor]`n" +
    "COM5   (USB)    Serial [USB: Product]`n" +
    "COM6   (USB)    Serial [Maker]`n" +
    "COM7   (USB)    Serial`n" +
    "COM8   (USB)    Serial`n" +
    "COM9   (Native) Serial [Microsoft Corporation]`n" +
    "COM10  (BL)     Serial`n" +
    "COM11  (USB)    Serial [Maker, USB: Vendor]`n" +
    "COM12  (USB)    Serial [Maker, USB: Product]`n"
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -ceq $expected) 'Compact optional metadata or separators are incorrect.'
$result = Invoke-Cli $fixture @('--verbose') 'compact-details'
Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
    $result.Stdout -match 'Manufacturer:\s+Microsoft\n' -and
    $result.Stdout -match 'Manufacturer:\s+Unknown\n') `
    'Compact metadata filtering changed verbose output.'
$verboseOutputs = @{}
$fullOnlyLabels = @('Instance ID', 'Hardware IDs', 'Driver version', 'Location',
    'USB instance', 'Driver provider', 'Service', 'Parent instance')
foreach ($flag in @('--verbose', '-v', '-d', '-vv')) {
    $result = Invoke-Cli $fixture @($flag) 'empty'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq "Found 0 ports:`n`n") 'Verbose empty summary is incorrect.'
    $result = Invoke-Cli $fixture @($flag) 'summary'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith("Found 6 ports (1 native, 2 bluetooth, 1 USB, 1 virtual, 1 unknown):`n`nCOM3`n")) `
        'Verbose transport summary differs from compact output.'
    $result = Invoke-Cli $fixture @($flag) 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith("Found 2 ports (1 USB, 1 unknown):`n`nCOM2`n") -and
        -not $result.Stdout.Contains([char]0xfffd) -and
        ($result.Stdout.Contains('0403:6001') -eq ($flag -eq '-vv')) -and
        $result.Stdout -match "USB vendor:\s+Example USB vendor $([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))" -and
        $result.Stdout -match "USB product:\s+Example USB product $([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))" -and
        $result.Stdout -match 'USB interface:\s+02' -and
        $result.Stdout.Contains("1234567890123456789012345$([char]::ConvertFromUtf32(0x1f600))") -and
        $result.Stdout.Contains('Example manufacturer with a long full name') -and
        $result.Stdout.Contains("$unicode (COM10)")) 'Verbose metadata is incomplete.'
    $verboseOutputs[$flag] = $result.Stdout
    foreach ($label in $fullOnlyLabels) {
        $present = $result.Stdout -match "(?m)^  $([regex]::Escape($label)):"
        Assert-True ($present -eq ($flag -eq '-vv')) "Wrong detail level for $label with $flag"
    }
    Assert-True ($result.Stdout.Contains('USB VID:PID:') -eq ($flag -eq '-vv')) `
        'Known vendor and product names did not control numeric USB IDs correctly.'
    $labels = @('Type', 'Description', 'Manufacturer',
        'USB vendor', 'USB product', 'USB interface')
    if ($flag -eq '-vv') { $labels += $fullOnlyLabels + @('USB VID:PID') }
    foreach ($label in $labels) {
        Assert-True ($result.Stdout -match "(?m)^  $([regex]::Escape($label)):\s+\S") `
            "Verbose label has no consistent colon or value: $label"
    }
    $detailLines = @($result.Stdout -split "`n" | Where-Object { $_.StartsWith('  ') })
    foreach ($line in $detailLines) {
        Assert-True ($line.Length -gt 19 -and $line[19] -ne ' ') `
            'Verbose detail values are not aligned.'
    }
    Assert-True (-not $result.Stdout.Contains([char]27)) 'Redirected verbose output contains color escapes.'
    $result = Invoke-Cli $fixture @($flag) 'compact'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout.StartsWith("Found 2 ports (1 bluetooth, 1 USB):`n`nCOM1`n") -and
        $result.Stdout.Contains('Bluetooth') -and
        $result.Stdout.Contains('USB Serial Port (COM1)') -and
        $result.Stdout.Contains('Bluetooth serial port (COM10)')) `
        'Verbose transport names or detail blocks are incorrect.'
    $headings = @([regex]::Matches($result.Stdout, '(?m)^COM\d+$') | ForEach-Object { $_.Value })
    Assert-True (($headings -join ',') -ceq 'COM1,COM10' -and
        $result.Stdout.Contains("`n`nCOM10`n") -and
        -not $result.Stdout.Contains('MANUFACTURER') -and
        -not $result.Stdout.Contains('PORT') -and
        -not ($result.Stdout -match '(?m)^COM\d+[ \t]+\S')) `
        'Verbose output retained a summary table or duplicated port headings.'
}
Assert-True ($verboseOutputs['-v'] -ceq $verboseOutputs['--verbose'] -and
    $verboseOutputs['-v'] -ceq $verboseOutputs['-d']) 'Detail aliases produce different output.'
$fullValues = @{
    'Instance ID' = 'USB\VID_0403&PID_6001&MI_02\EXAMPLE'
    'Hardware IDs' = 'USB\VID_0403&PID_6001&REV_0600'
    'Driver version' = '2.12.36.4'
    'Location' = 'Port_#0001.Hub_#0002'
    'USB instance' = 'USB\VID_0403&PID_6001&MI_02\EXAMPLE'
    'Driver provider' = 'Example driver provider'
    'Service' = 'FTSER2K'
    'Parent instance' = 'USB\VID_0403&PID_6001\PARENT'
}
foreach ($label in $fullOnlyLabels) {
    Assert-True ($verboseOutputs['-vv'] -match
        "(?m)^  $([regex]::Escape($label)):\s+$([regex]::Escape($fullValues[$label]))$") `
        "Full diagnostics lost the value of $label"
    Assert-True (-not $verboseOutputs['-v'].Contains($fullValues[$label])) `
        "Normal details leaked the value of $label"
}
foreach ($arguments in @(@('-v', '-v'), @('--verbose', '--verbose'), @('-d', '-d'),
    @('-vv', '-v'), @('-v', '-vv'), @('-vv', '-d'), @('-v', '-d', '--verbose'))) {
    $result = Invoke-Cli $fixture $arguments 'unicode'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq $verboseOutputs['-vv']) 'Repeated detail flags did not select the full level.'
}
foreach ($binary in @($fixture, $noIds, $badIds)) {
    foreach ($detailFlag in @('-d', '-vv')) {
        foreach ($infoFlag in @('--help', '--version')) {
            $result = Invoke-Cli $binary @($detailFlag, $infoFlag)
            Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
                $result.Stdout.Length -gt 0) 'Detail flags triggered discovery with help/version.'
        }
    }
}
foreach ($case in @(
    @{ Scenario = 'usb-unknown'; Vendor = 'Unknown'; Product = 'Unknown'; Suffix = '' },
    @{ Scenario = 'usb-vendor-only'; Vendor = 'Vendor without products'; Product = 'Unknown'; Suffix = ', USB: Vendor without products' }
)) {
    foreach ($flag in @('--verbose', '-v', '-d', '-vv')) {
        $result = Invoke-Cli $fixture @($flag) $case.Scenario
        $vid = if ($case.Scenario -eq 'usb-unknown') { '0001' } else { '5678' }
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
            $result.Stdout -match "USB vendor:\s+$($case.Vendor)\n" -and
            $result.Stdout -match "USB product:\s+$($case.Product)\n" -and
            $result.Stdout -match "USB VID:PID:\s+${vid}:6001\n" -and
            $result.Stdout -match 'Manufacturer:\s+Windows manufacturer\n' -and
            $result.Stdout -match 'Description:\s+Windows description\n') `
            'Unknown USB names hid numeric IDs or changed Windows metadata.'
    }
    $result = Invoke-Cli $fixture @() $case.Scenario
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq "Found 1 port (1 USB):`n`nCOM1  (USB) Windows description [Windows manufacturer$($case.Suffix)]`n") `
        'Compact output did not preserve Windows metadata or handle unknown USB IDs.'
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
    foreach ($case in @(
        @{ Scenario = 'bluetooth-usb'; Type = 'BL'; Summary = 'bluetooth' },
        @{ Scenario = 'usb-no-ids'; Type = 'USB'; Summary = 'USB' }
    )) {
        $result = Invoke-Cli $binary @() $case.Scenario
        $type = "($($case.Type))".PadRight(5)
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
            $result.Stdout -ceq "Found 1 port (1 $($case.Summary)):`n`nCOM1  $type Windows description [Windows manufacturer]`n") `
            'Compact output without USB identities or for Bluetooth required the database or added USB names.'
    }
    foreach ($scenario in @('empty', 'single')) {
        $result = Invoke-Cli $binary @() $scenario
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') `
            'Compact output without USB ports required the database.'
    }
}
foreach ($binary in @($noIds, $badIds)) {
    foreach ($arguments in @(@(), @('--verbose'), @('-d'), @('-vv'),
        @('-u'), @('--usb-only', '-v'), @('-u', '-vv'))) {
        $result = Invoke-Cli $binary $arguments 'unicode'
        Assert-True ($result.ExitCode -eq 1 -and $result.Stdout -eq '' -and
            $result.Stderr.Contains('Loading embedded USB database')) `
            'Missing or corrupt USB resource was not reported before output.'
    }
}
foreach ($arguments in @(@(), @('--verbose'), @('-v'), @('-d'), @('-vv'),
    @('-u'), @('--usb-only', '-v'), @('-u', '-vv'))) {
    $result = Invoke-Cli $exe $arguments
    $prefix = '^Found [0-9]+ ports?( \([^\r\n]+\))?:\n\n'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -match $prefix) `
        "Real device enumeration failed: $($result.Stderr)"
}
$standalone = Join-Path $root "build\standalone-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $standalone -Force | Out-Null
$copiedExe = Join-Path $standalone 'comls.exe'
Copy-Item -LiteralPath $exe -Destination $copiedExe -Force
Push-Location $standalone
try {
    foreach ($arguments in @(@(), @('--verbose'), @('-vv'))) {
        $result = Invoke-Cli $copiedExe $arguments
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') `
            'Standalone copied executable failed without external database files.'
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $copiedExe
    Remove-Item -LiteralPath $standalone
}
Write-Host 'CLI smoke tests passed (including USB enrichment, resource errors, and standalone execution).'
