#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\usb-ids.ps1')
$build = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build'))
$work = Join-Path $build 'usb_ids_tests'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-True $rejected $Message
}

$unicode = "$([char]0x65e5)$([char]::ConvertFromUtf32(0x1f600))"
$source = @"
# Synthetic USB database, intentionally unsorted.
ffff  Last vendor
`tffff  Last product
5678  Vendor without products
1234  Other vendor
`t6001  Other product
0403  Example USB vendor $unicode
`t6001  Example USB product $unicode
`t`t00  Ignored interface
`t0001  First product
0000  First vendor
`t0000  Zero product
C 00  Ignored class
`t01  Ignored subclass
`t`t01  Ignored protocol
AT 0100  Ignored audio terminal
`t6001  Not a product
"@
$inputPath = Join-Path $work 'source.ids'
$outputPath = Join-Path $build 'test_usb_ids.bin'
[System.IO.File]::WriteAllText($inputPath, $source, $utf8)
$vendors = Read-UsbIds $inputPath
Assert-True ($vendors.Count -eq 5) 'Incorrect vendor count.'
Assert-True ($vendors[0x0403].Products.Count -eq 2) 'Ignored sections became products.'
Assert-True ($vendors[0x0403].Name -ceq "Example USB vendor $unicode") 'UTF-8 name changed.'
Write-UsbIdsBinary $vendors $outputPath
$second = Join-Path $work 'second.bin'
Write-UsbIdsBinary (Read-UsbIds $inputPath) $second
Assert-True ((Get-FileHash $outputPath).Hash -eq (Get-FileHash $second).Hash) `
    'Binary generation is not deterministic.'
$reordered = ($source -replace 'ffff  Last vendor\r?\n\tffff  Last product\r?\n', '') `
    -replace 'C 00', "ffff  Last vendor`n`tffff  Last product`nC 00"
[System.IO.File]::WriteAllText($inputPath, $reordered, $utf8)
Write-UsbIdsBinary (Read-UsbIds $inputPath) $second
Assert-True ((Get-FileHash $outputPath).Hash -eq (Get-FileHash $second).Hash) `
    'Source ordering changed the binary.'
[System.IO.File]::WriteAllText($inputPath, ($source -replace '\r?\n', "`r`n"),
    [System.Text.UTF8Encoding]::new($true, $true))
Write-UsbIdsBinary (Read-UsbIds $inputPath) $second
Assert-True ((Get-FileHash $outputPath).Hash -eq (Get-FileHash $second).Hash) `
    'UTF-8 BOM or CRLF changed the binary.'

$invalidPath = Join-Path $work 'invalid.ids'
foreach ($invalid in @(
    '',
    'An HTML download error',
    "0001  No products",
    "`t0001  Orphan product",
    "`t`t00  Orphan interface",
    "0001  Vendor`n`t0001  Product`n0001  Duplicate",
    "0001  Vendor`n`t0001  Product`n`t0001  Duplicate",
    "0001  Vendor`n`t0001",
    "0001  Vendor`n`t0001  Product`nGGGG  Invalid vendor",
    "0001  Vendor`n`t0001  Product`n0002  ",
    "0001  Vendor`n`t0001  Product$([char]0)"
)) {
    [System.IO.File]::WriteAllText($invalidPath, $invalid, $utf8)
    Assert-Rejected { $null = Read-UsbIds $invalidPath } 'Invalid source was accepted.'
}
$invalidUtf8 = [byte[]](@(0x30, 0x30, 0x30, 0x31, 0x20, 0x20, 0xff))
[System.IO.File]::WriteAllBytes($invalidPath, $invalidUtf8)
Assert-Rejected { $null = Read-UsbIds $invalidPath } 'Invalid UTF-8 vendor was accepted.'
[System.IO.File]::WriteAllBytes($invalidPath,
    ($utf8.GetBytes("0001  Vendor`n`t0001  ") + [byte[]]@(0xff)))
Assert-Rejected { $null = Read-UsbIds $invalidPath } 'Invalid UTF-8 product was accepted.'
[System.IO.File]::WriteAllText($invalidPath, $source, [System.Text.Encoding]::Unicode)
Assert-Rejected { $null = Read-UsbIds $invalidPath } 'UTF-16 input was accepted as UTF-8.'
[System.IO.File]::WriteAllBytes($invalidPath,
    ($utf8.GetBytes("0001  Vendor`n`t0001  Product`nC 00  Class`n") + [byte[]]@(0xb4)))
Assert-True ((Read-UsbIds $invalidPath).Count -eq 1) 'Legacy bytes in ignored sections broke parsing.'
[System.IO.File]::WriteAllBytes((Join-Path $build 'bad_usb_ids.bin'), [byte[]]@(0, 1, 2))

$destination = Join-Path $work 'updated.ids'
[System.IO.File]::WriteAllText($destination, $source, $utf8)
$originalHash = (Get-FileHash $destination).Hash
$script:downloadMode = 'invalid'
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
    Assert-True ($Uri -ceq 'https://usb-ids.gowdy.us/usb.ids' -and
        $TimeoutSec -eq 60 -and $MaximumRedirection -eq 0) 'Unsafe download settings.'
    if ($script:downloadMode -eq 'network-error') {
        [System.IO.File]::WriteAllText($OutFile, 'partial download', $utf8)
        throw 'Synthetic network error.'
    }
    $content = if ($script:downloadMode -eq 'valid') { $source + "`n# Updated" } else { 'invalid download' }
    [System.IO.File]::WriteAllText($OutFile, $content, $utf8)
}
try {
    foreach ($mode in @('invalid', 'network-error')) {
        $script:downloadMode = $mode
        Assert-Rejected { Update-UsbIds $destination } 'Failed update was accepted.'
        Assert-True ((Get-FileHash $destination).Hash -eq $originalHash) 'Failed update changed the snapshot.'
        Assert-True (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count -eq 0) `
            'Failed update left temporary files.'
    }
    $script:downloadMode = 'valid'
    Update-UsbIds $destination
    Assert-True ((Get-FileHash $destination).Hash -ne $originalHash) 'Valid update did not replace the snapshot.'
    Assert-True ((Read-UsbIds $destination).Count -eq 5) 'Updated snapshot is invalid.'
    Assert-True (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count -eq 0) `
        'Successful update left temporary files.'
} finally {
    Remove-Item Function:\Invoke-WebRequest
}
Write-Host 'USB source conversion and update tests passed.'
