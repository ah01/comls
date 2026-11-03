#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\usb-ids.ps1')
. (Join-Path $PSScriptRoot '..\scripts\raspberrypi-usb-pid.ps1')
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'build\raspberrypi_tests'
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
$table = @"
# Synthetic assignments
Vendor-ID = 0x2E8A

| Product ID | Company | Product Description | Product link |
| --- | --- | --- | --- |
| **Internal** | | | |
| 0xABCD | Example | Unicode $unicode | https://example.com |
| **0x1000 - 0x1fff** ||||
| 0x0000 | Example | Zero product |
| 0x0001 | Reserved 2 | Must not become a name | |
| 0x0002 | Example | | |
| 0x0003 | Example | Supplemental product | https://example.com
"@
$tablePath = Join-Path $work 'Readme.md'
[System.IO.File]::WriteAllText($tablePath, $table, $utf8)
$products = Read-RaspberryPiTable $tablePath
Assert-True ($products.Count -eq 3 -and $products[0xabcd] -ceq "Unicode $unicode" -and
    $products[0] -ceq 'Zero product' -and $products[3] -ceq 'Supplemental product') `
    'Assignment table parsing changed names or included reserved products.'
[System.IO.File]::WriteAllText($tablePath, ($table -replace '\r?\n', "`r`n"),
    [System.Text.UTF8Encoding]::new($true, $true))
Assert-True ((Read-RaspberryPiTable $tablePath).Count -eq 3) 'BOM/CRLF broke table parsing.'
foreach ($invalid in @(
    '',
    $table.Replace('0x2E8A', '0x1234'),
    $table.Replace('Product Description', 'Description'),
    $table.Replace('| --- | --- | --- | --- |', '| --- |'),
    $table.Replace('0xABCD', '0x10000'),
    $table.Replace('0xABCD', '0xGGGG'),
    $table.Replace('0xABCD', '0x0003'),
    $table.Replace('Supplemental product', "Invalid$([char]0)name"),
    ($table + "`n| 0x1234 | Missing description column |"),
    ($table + "`nUnexpected format change"),
    ($table + "`nVendor-ID = 0x2E8A"),
    ($table + "`n| Product ID | Company | Product Description | Product link |"),
    ($table -replace '(?m)^\| 0x.*$', '')
)) {
    [System.IO.File]::WriteAllText($tablePath, $invalid, $utf8)
    Assert-Rejected { $null = Read-RaspberryPiTable $tablePath } 'Invalid upstream table was accepted.'
}
[System.IO.File]::WriteAllBytes($tablePath, ($utf8.GetBytes($table) + [byte[]]@(0xff)))
Assert-Rejected { $null = Read-RaspberryPiTable $tablePath } 'Invalid UTF-8 table was accepted.'
[System.IO.File]::WriteAllText($tablePath, $table, [System.Text.Encoding]::Unicode)
Assert-Rejected { $null = Read-RaspberryPiTable $tablePath } 'UTF-16 table was accepted.'

$snapshotPath = Join-Path $work 'snapshot.json'
$sha = '0123456789012345678901234567890123456789'
$timestamp = '2025-02-28T12:34:56Z'
$script:mode = 'valid'
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $MaximumRedirection)
    Assert-True ($Uri -ceq
        'https://api.github.com/repos/raspberrypi/usb-pid/commits?path=Readme.md&per_page=1' -and
        $TimeoutSec -eq 60 -and $MaximumRedirection -eq 0) 'Unsafe revision request.'
    if ($script:mode -eq 'revision-error') { throw 'Synthetic revision network failure.' }
    $revision = if ($script:mode -eq 'bad-sha') { 'invalid' } else { $sha }
    $date = switch ($script:mode) {
        'bad-date' { 'invalid' }
        'null-date' { $null }
        default { $timestamp }
    }
    return [pscustomobject]@{
        sha = $revision
        commit = [pscustomobject]@{ committer = [pscustomobject]@{ date = $date } }
    }
}
$usbSource = "# Date: 2025-02-28 12:34:56`n1234  Other vendor`n`t0003  Other product`n"
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
    Assert-True ($TimeoutSec -eq 60 -and $MaximumRedirection -eq 0) 'Unsafe download settings.'
    if ($Uri -ceq 'https://usb-ids.gowdy.us/usb.ids') {
        $content = if ($script:mode -eq 'bad-usb') { 'invalid' } else { $usbSource }
    } else {
        Assert-True ($Uri -ceq "https://raw.githubusercontent.com/raspberrypi/usb-pid/$sha/Readme.md") `
            'Source download was not pinned to the requested commit.'
        $content = if ($script:mode -eq 'bad-table') { 'invalid' } else { $table }
        if ($script:mode -eq 'table-error') {
            [System.IO.File]::WriteAllText($OutFile, 'partial download', $utf8)
            throw 'Synthetic source network failure.'
        }
    }
    [System.IO.File]::WriteAllText($OutFile, $content, $utf8)
}
try {
    Update-RaspberryPiSnapshot $snapshotPath
    $snapshot = Read-RaspberryPiSnapshot $snapshotPath
    Assert-True ($snapshot.Date -ceq '2025-02-28' -and $snapshot.Commit -ceq $sha -and
        $snapshot.Products.Count -eq 3) 'Snapshot provenance or products changed.'
    $hash = (Get-FileHash $snapshotPath).Hash
    $json = [System.IO.File]::ReadAllText($snapshotPath)
    Update-RaspberryPiSnapshot $snapshotPath
    Assert-True ((Get-FileHash $snapshotPath).Hash -eq $hash) 'Snapshot is not deterministic.'
    $originalTable = $table
    $firstRow = "| 0xABCD | Example | Unicode $unicode | https://example.com |"
    $table = $table.Replace($firstRow, '') + "`n$firstRow"
    Update-RaspberryPiSnapshot $snapshotPath
    Assert-True ((Get-FileHash $snapshotPath).Hash -eq $hash) 'Source ordering changed the snapshot.'
    $table = $originalTable
    foreach ($invalid in @(
        '{}',
        $json.Replace('raspberrypi/usb-pid', 'other/repository'),
        $json.Replace('Readme.md', 'other.md'),
        $json.Replace($sha, 'invalid'),
        $json.Replace($sha, "$sha\n"),
        $json.Replace($timestamp, '2025-02-29T12:34:56Z'),
        $json.Replace('"0000"', '"10000"'),
        $json.Replace('"0000"', '"0003"'),
        $json.Replace('Zero product', 'Invalid\u0000name'),
        $json.Replace('Zero product', '')
    )) {
        [System.IO.File]::WriteAllText($snapshotPath, $invalid, $utf8)
        Assert-Rejected { $null = Read-RaspberryPiSnapshot $snapshotPath } 'Invalid snapshot was accepted.'
    }
    [System.IO.File]::WriteAllText($snapshotPath, $json, $utf8)
    $usbPath = Join-Path $work 'usb.ids'
    [System.IO.File]::WriteAllText($usbPath, $usbSource, $utf8)
    $vendors = Read-UsbIds $usbPath
    Merge-RaspberryPiProducts $vendors $snapshot
    Assert-True ($vendors.Count -eq 2 -and $vendors[0x2e8a].Name -ceq 'Raspberry Pi' -and
        $vendors[0x2e8a].Products.Count -eq 3 -and
        $vendors[0x1234].Products[3] -ceq 'Other product') 'Merge escaped VID 2E8A or lost products.'
    $vendors[0x2e8a].Name = 'Existing vendor'
    $vendors[0x2e8a].Products[3] = 'Existing product'
    Merge-RaspberryPiProducts $vendors $snapshot
    Assert-True ($vendors[0x2e8a].Name -ceq 'Existing vendor' -and
        $vendors[0x2e8a].Products[3] -ceq 'Existing product') 'Supplement replaced usb.ids names.'
    $binary = Join-Path $work 'merged.bin'
    Write-UsbIdsBinary $vendors $binary
    $binaryHash = (Get-FileHash $binary).Hash
    Merge-RaspberryPiProducts $vendors $snapshot
    Write-UsbIdsBinary $vendors $binary
    Assert-True ((Get-FileHash $binary).Hash -eq $binaryHash) 'Repeated merging changed the binary.'

    $originalUsb = "# Previous snapshot`n$usbSource"
    [System.IO.File]::WriteAllText($usbPath, $originalUsb, $utf8)
    $usbHash = (Get-FileHash $usbPath).Hash
    foreach ($mode in @('revision-error', 'bad-sha', 'bad-date', 'null-date', 'bad-table',
        'table-error', 'bad-usb')) {
        $script:mode = $mode
        Assert-Rejected { Update-UsbDatabases $usbPath $snapshotPath } 'Failed paired update was accepted.'
        Assert-True ((Get-FileHash $usbPath).Hash -eq $usbHash -and
            (Get-FileHash $snapshotPath).Hash -eq $hash) 'Failed update changed the snapshot pair.'
        Assert-True (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count -eq 0) `
            'Failed update left temporary files.'
    }
    $script:mode = 'valid'
    $blockedPath = Join-Path $work 'blocked.json'
    New-Item -ItemType Directory -Path $blockedPath -Force | Out-Null
    try {
        Assert-Rejected { Update-UsbDatabases $usbPath $blockedPath } 'Invalid destination was accepted.'
        Assert-True ((Get-FileHash $usbPath).Hash -eq $usbHash) 'Replacement failure did not roll back usb.ids.'
    } finally {
        Remove-Item -LiteralPath $blockedPath
    }
    Update-UsbDatabases $usbPath $snapshotPath
    Assert-True ((Get-FileHash $usbPath).Hash -ne $usbHash -and
        (Get-FileHash $snapshotPath).Hash -eq $hash) 'Successful paired update changed source data.'
    Assert-True (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count -eq 0) `
        'Successful update left temporary files.'
} finally {
    Remove-Item Function:\Invoke-RestMethod
    Remove-Item Function:\Invoke-WebRequest
}

$base = Read-UsbIds (Join-Path $root 'data\usb.ids')
$production = Read-RaspberryPiSnapshot (Join-Path $root 'data\raspberrypi-usb-pid.json')
$added = @($production.Products.Keys | Where-Object {
    -not $base.ContainsKey(0x2e8a) -or -not $base[0x2e8a].Products.ContainsKey($_)
})
Assert-True ($added.Count -gt 0) 'Production supplement adds no products.'
Merge-RaspberryPiProducts $base $production
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'build\usb_ids.bin'))
function Read-U32([int]$Offset) { return [BitConverter]::ToUInt32($bytes, $Offset) }
function Read-Name([int]$Offset) {
    $start = (Read-U32 20) + $Offset
    $end = [Array]::IndexOf($bytes, [byte]0, [int]$start)
    Assert-True ($end -ge $start) 'Missing binary string terminator.'
    return $utf8.GetString($bytes, $start, $end - $start)
}
Assert-True ((Read-U32 12) -eq $base.Count) 'Production binary vendor count changed.'
$vendorIndex = 0
$expectedProducts = 0
foreach ($vendor in $base.Values) {
    $offset = 32 + $vendorIndex * 16
    Assert-True ((Read-U32 $offset) -eq $vendor.Id -and
        (Read-Name (Read-U32 ($offset + 4))) -ceq $vendor.Name -and
        (Read-U32 ($offset + 12)) -eq $vendor.Products.Count) 'Production binary vendor mismatch.'
    $productIndex = Read-U32 ($offset + 8)
    foreach ($product in $vendor.Products.GetEnumerator()) {
        $productOffset = 32 + $base.Count * 16 + $productIndex * 8
        Assert-True ((Read-U32 $productOffset) -eq $product.Key -and
            (Read-Name (Read-U32 ($productOffset + 4))) -ceq $product.Value) `
            'Production binary product mismatch.'
        ++$productIndex
        ++$expectedProducts
    }
    ++$vendorIndex
}
Assert-True ((Read-U32 16) -eq $expectedProducts) 'Production binary product count changed.'
Write-Host "Raspberry Pi PID tests passed ($($production.Products.Count) assignments, $($added.Count) new products)."
