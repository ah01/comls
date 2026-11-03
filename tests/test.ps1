#requires -Version 7.0
[CmdletBinding()]
param([string]$ExpectedVersion)

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
$version = if ($ExpectedVersion) { $ExpectedVersion } else { $match.Groups[1].Value }
$snapshot = [System.IO.File]::ReadAllText((Join-Path $root 'data\usb.ids'),
    [System.Text.Encoding]::Latin1)
$dateMatch = [regex]::Match($snapshot, '(?m)^# Date:\s*(\d{4}-\d{2}-\d{2}) ')
Assert-True $dateMatch.Success 'Upstream USB snapshot date was not found.'
$usbDate = $dateMatch.Groups[1].Value
. (Join-Path $root 'scripts\raspberrypi-usb-pid.ps1')
$raspberryPi = Read-RaspberryPiSnapshot (Join-Path $root 'data\raspberrypi-usb-pid.json')
$versionOutput = "comls $version`n`nUSB vendor and product ID sources:`n" +
    "  usb.ids: $usbDate`n" +
    "  raspberrypi/usb-pid: $($raspberryPi.Date) ($($raspberryPi.Commit))`n"
foreach ($binary in @($exe, $fixture, $noIds, $badIds)) {
    $result = Invoke-Cli $binary @('--version')
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq $versionOutput -and
        $result.Stderr -eq '') 'Version output or exit code is incorrect.'
    foreach ($flag in @('--help', '-h')) {
        $result = Invoke-Cli $binary @($flag)
        Assert-True ($result.ExitCode -eq 0 -and $result.Stdout.Contains('--version') -and
            $result.Stdout.Contains('--usb-only') -and
            $result.Stdout.Contains('--sort-by-time') -and
            $result.Stdout.Contains('-d') -and $result.Stdout.Contains('-vv') -and
            $result.Stderr -eq '') 'Help output is incorrect or triggered discovery.'
    }
    foreach ($arguments in @(@('--bad'), @('COM1'), @('--version', '--bad'), @('-u', '--bad'),
        @('-vvv'), @('-d', '--bad'), @('-vv', '--bad'), @('-t', '--bad'),
        @('--sort-by-time', '--bad'), @('-tt'))) {
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
foreach ($scenario in @('arrivals', 'all-recent', 'old-arrivals')) {
    $result = Invoke-Cli $fixture @() $scenario
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        -not $result.Stdout.Contains([char]27)) 'Arrival compact output failed or contains escapes.'
    $rows = @([regex]::Matches($result.Stdout, '(?m)^COM\d+.*$') |
        ForEach-Object { $_.Value })
    $names = @($rows | ForEach-Object { ($_ -split '\s+')[0] })
    $recentNames = 'COM2,COM5,COM6,COM7,COM8,COM10'
    $restNames = 'COM1,COM3,COM4,COM9,COM11,COM12,COM13,COM14,COM15,COM16'
    $expectedNames = switch ($scenario) {
        'arrivals' { "$recentNames,$restNames" }
        'all-recent' { $recentNames }
        'old-arrivals' { $restNames }
    }
    Assert-True (($names -join ',') -ceq $expectedNames) 'Recent partition lost ports or numeric ordering.'
    Assert-True ($result.Stdout.Contains('Recent (last 5 minutes):') -eq
        ($scenario -ne 'old-arrivals')) 'Recent heading visibility is incorrect.'
    Assert-True ($result.Stdout.Contains("`n`nRest:`n") -eq ($scenario -eq 'arrivals')) `
        'Rest heading visibility or separation is incorrect.'
    foreach ($row in $rows) {
        $descriptionColumn = if ($scenario -eq 'all-recent') { 13 } else { 17 }
        Assert-True ($row.IndexOf('(') -eq 7 -and $row.IndexOf('Serial') -eq $descriptionColumn) `
            'Grouped compact columns are not aligned across sections.'
    }
    if ($scenario -eq 'arrivals') {
        Assert-True ($result.Stdout.StartsWith(
            "Found 16 ports (8 native, 1 bluetooth, 6 USB, 1 unknown):`n`nRecent (last 5 minutes):`n")) `
            'Grouped output changed summary counts or layout.'
        $sections = $result.Stdout -split "`n`nRest:`n"
        Assert-True ((@([regex]::Matches($sections[0], '(?m)^COM\d+') |
            ForEach-Object { $_.Value }) -join ',') -ceq $recentNames) `
            'Recent contains old, unknown, or future timestamps.'
    }
}
foreach ($flag in @('-u', '--usb-only')) {
    $result = Invoke-Cli $fixture @($flag) 'arrivals'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        $result.Stdout -ceq ("Found 6 ports (6 USB):`n`nRecent (last 5 minutes):`n" +
            "COM2   (USB) Serial +5 min`nCOM6   (USB) Serial +2 min`nCOM7   (USB) Serial +1 min`n" +
            "COM8   (USB) Serial +1 s`nCOM10  (USB) Serial +1 min`n`nRest:`nCOM4   (USB) Serial -1 min`n")) `
        'USB filtering, grouping, counts, or column widths are incorrect.'
}
$reference = [datetime]::new(2026, 1, 15, 12, 0, 0, [DateTimeKind]::Utc)
$arrivalCases = @(
    @{ Name = 'COM1'; Age = 301; Relative = '5 minutes ago' },
    @{ Name = 'COM2'; Age = 300; Relative = '5 minutes ago' },
    @{ Name = 'COM4'; Age = -60; Relative = 'in 1 minute' },
    @{ Name = 'COM5'; Age = 0; Relative = 'just now' },
    @{ Name = 'COM6'; Age = 120; Relative = '2 minutes ago' },
    @{ Name = 'COM7'; Age = 60; Relative = '1 minute ago' },
    @{ Name = 'COM8'; Age = 1; Relative = '1 second ago' },
    @{ Name = 'COM9'; Age = 3600; Relative = '1 hour ago' },
    @{ Name = 'COM10'; Age = 60; Relative = '1 minute ago' },
    @{ Name = 'COM11'; Age = 86400; Relative = '1 day ago' },
    @{ Name = 'COM12'; Age = 172800; Relative = '2 days ago' },
    @{ Name = 'COM13'; Age = 7200; Relative = '2 hours ago' },
    @{ Name = 'COM14'; Age = -7200; Relative = 'in 2 hours' },
    @{ Name = 'COM15'; Age = (184 * 86400); Relative = '184 days ago' },
    @{ Name = 'COM16'; Age = 0; Relative = 'in less than a second' }
)
$compact = Invoke-Cli $fixture @() 'arrivals'
foreach ($case in $arrivalCases) {
    $age = switch -Regex ($case.Relative) {
        '^(\d+) seconds? ago$' { "+$($Matches[1]) s"; break }
        '^(\d+) minutes? ago$' { "+$($Matches[1]) min"; break }
        '^(\d+) hours? ago$' { "+$($Matches[1]) h"; break }
        '^(\d+) days? ago$' { "+$($Matches[1]) d"; break }
        '^in (\d+) minutes?$' { "-$($Matches[1]) min"; break }
        '^in (\d+) hours?$' { "-$($Matches[1]) h"; break }
        '^in less than a second$' { '-0 s'; break }
        '^just now$' { '+0 s'; break }
    }
    Assert-True ($compact.Stdout -match
        "(?m)^$($case.Name)\s+.* $([regex]::Escape($age))$") `
        "Compact arrival age is missing or incorrect for $($case.Name)."
}
Assert-True ($compact.Stdout -match '(?m)^COM3\s+\(Unknown\) Serial$') `
    'Unknown compact arrival age was not omitted.'
foreach ($sortFlag in @('-t', '--sort-by-time')) {
    foreach ($detailFlags in @(@(), @('-v'), @('-d'), @('-vv'))) {
        $sorted = Invoke-Cli $fixture (@($sortFlag) + $detailFlags) 'arrivals'
        $names = @([regex]::Matches($sorted.Stdout, '(?m)^COM\d+') |
            ForEach-Object { $_.Value })
        $expected = if ($detailFlags.Count) {
            'COM14,COM4,COM16,COM5,COM8,COM7,COM10,COM6,COM2,COM1,COM9,COM13,COM11,COM12,COM15,COM3'
        } else {
            'COM5,COM8,COM7,COM10,COM6,COM2,COM14,COM4,COM16,COM1,COM9,COM13,COM11,COM12,COM15,COM3'
        }
        Assert-True ($sorted.ExitCode -eq 0 -and $sorted.Stderr -eq '' -and
            ($names -join ',') -ceq $expected) 'Time sorting or arrival-time tie breaking is incorrect.'
        $filtered = Invoke-Cli $fixture (@($sortFlag, '-u') + $detailFlags) 'arrivals'
        $names = @([regex]::Matches($filtered.Stdout, '(?m)^COM\d+') |
            ForEach-Object { $_.Value })
        $expected = if ($detailFlags.Count) { 'COM4,COM8,COM7,COM10,COM6,COM2' } else {
            'COM8,COM7,COM10,COM6,COM2,COM4'
        }
        Assert-True ($filtered.ExitCode -eq 0 -and $filtered.Stderr -eq '' -and
            ($names -join ',') -ceq $expected) 'USB time sorting is incorrect.'
    }
    foreach ($scenario in @('empty', 'single', 'compact')) {
        $normal = Invoke-Cli $fixture @() $scenario
        $sorted = Invoke-Cli $fixture @($sortFlag, $sortFlag) $scenario
        Assert-True ($sorted.ExitCode -eq 0 -and $sorted.Stderr -eq '' -and
            $sorted.Stdout -ceq $normal.Stdout) 'Unknown arrival sorting or repeated time flags changed output.'
    }
    foreach ($infoFlag in @('--help', '--version')) {
        $result = Invoke-Cli $fixture @($sortFlag, $infoFlag) 'error'
        Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '') `
            'Time sorting triggered discovery with help/version.'
    }
}
foreach ($flag in @('-v', '--verbose', '-d', '-vv')) {
    $result = Invoke-Cli $fixture @($flag) 'arrivals'
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr -eq '' -and
        -not $result.Stdout.Contains('Recent (') -and -not $result.Stdout.Contains('Rest:')) `
        'Verbose arrival output failed or was grouped.'
    $blocks = @{}
    foreach ($block in ($result.Stdout -split "`n`n")) {
        if ($block -match '^(COM\d+)\n') { $blocks[$Matches[1]] = $block }
    }
    Assert-True (($blocks.Keys.Count -eq 16) -and
        $blocks['COM3'].Contains('Last arrival:    Unknown')) 'Missing arrival is not Unknown.'
    foreach ($case in $arrivalCases) {
        $utc = $reference.AddSeconds(-$case.Age)
        $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, [TimeZoneInfo]::Local)
        $absolute = $local.ToString('yyyy-MM-dd HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture)
        $expected = "  Last arrival:    $absolute ($($case.Relative))`n"
        Assert-True ($blocks[$case.Name].Contains($expected)) `
            "Incorrect local time or relative age for $($case.Name) with $flag."
    }
    $headings = @([regex]::Matches($result.Stdout, '(?m)^COM\d+$') |
        ForEach-Object { $_.Value })
    Assert-True (($headings -join ',') -ceq
        'COM1,COM2,COM3,COM4,COM5,COM6,COM7,COM8,COM9,COM10,COM11,COM12,COM13,COM14,COM15,COM16') `
        'Verbose arrival details changed numeric ordering.'
    $filtered = Invoke-Cli $fixture @($flag, '-u') 'arrivals'
    Assert-True ($filtered.ExitCode -eq 0 -and $filtered.Stderr -eq '' -and
        ([regex]::Matches($filtered.Stdout, '(?m)^  Last arrival:').Count -eq 6) -and
        -not $filtered.Stdout.Contains('Recent (')) 'USB-only verbose arrivals are incorrect.'
    $invalid = Invoke-Cli $fixture @($flag) 'invalid-arrival'
    Assert-True ($invalid.ExitCode -eq 1 -and
        $invalid.Stderr.Contains('Writing standard output')) 'Timestamp conversion failure was hidden.'
    $seconds = Invoke-Cli $fixture @($flag) 'relative-seconds'
    Assert-True ($seconds.ExitCode -eq 0 -and $seconds.Stderr -eq '' -and
        $seconds.Stdout.Contains('(59 seconds ago)')) 'Plural relative seconds are incorrect.'
}
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
    $result = Invoke-Cli $copiedExe @('--version')
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -ceq $versionOutput -and
        $result.Stderr -eq '') 'Standalone version output requires external files.'
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
