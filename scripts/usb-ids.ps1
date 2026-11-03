#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-UsbIdsDate([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Latin1)
    $dates = [regex]::Matches($text, '(?m)^# Date:[ \t]*([^\r\n]*)')
    if ($dates.Count -ne 1) {
        throw 'usb.ids must contain exactly one upstream Date header.'
    }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dates[0].Groups[1].Value.Trim(),
        'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw 'usb.ids has an invalid upstream Date header.'
    }
    return $date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Read-UsbIds([string]$Path) {
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $vendors = [System.Collections.Generic.SortedDictionary[int, object]]::new()
    $vendor = $null
    $otherSection = $false
    $lineNumber = 0
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { $start = 3 }
    # Parse ASCII syntax without decoding legacy bytes in unused sections.
    $text = [System.Text.Encoding]::Latin1.GetString($bytes, $start, $bytes.Length - $start)
    foreach ($rawLine in $text.Split("`n")) {
        $line = $rawLine.TrimEnd("`r")
        ++$lineNumber
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line.Contains([char]0)) { throw "NUL in usb.ids at line $lineNumber." }
        if ($line -cmatch '^C [0-9a-fA-F]{2}[ ]+\S') {
            $otherSection = $true
            $vendor = $null
        }
        if ($otherSection) { continue }
        if ($line.StartsWith("`t`t") -and $null -ne $vendor) { continue }
        if ($line -cmatch '^([0-9a-fA-F]{4})[ ]+(\S.*)$') {
            $id = [Convert]::ToInt32($Matches[1], 16)
            if ($vendors.ContainsKey($id)) { throw "Duplicate vendor at line $lineNumber." }
            $vendor = [pscustomobject]@{
                Id = $id
                Name = $utf8.GetString([System.Text.Encoding]::Latin1.GetBytes($Matches[2].TrimEnd(' ')))
                Products = [System.Collections.Generic.SortedDictionary[int, string]]::new()
            }
            $vendors.Add($id, $vendor)
        } elseif ($line -cmatch '^\t([0-9a-fA-F]{4})[ ]+(\S.*)$' -and $null -ne $vendor) {
            $id = [Convert]::ToInt32($Matches[1], 16)
            if ($vendor.Products.ContainsKey($id)) { throw "Duplicate product at line $lineNumber." }
            $vendor.Products.Add($id,
                $utf8.GetString([System.Text.Encoding]::Latin1.GetBytes($Matches[2].TrimEnd(' '))))
        } else {
            throw "Invalid vendor/product record at line $lineNumber."
        }
    }
    $productCount = 0
    foreach ($entry in $vendors.Values) { $productCount += $entry.Products.Count }
    if ($vendors.Count -eq 0 -or $productCount -eq 0) {
        throw 'usb.ids must contain vendors and products.'
    }
    return ,$vendors
}

function Write-UsbIdsBinary($Vendors, [string]$Path) {
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $strings = [System.IO.MemoryStream]::new()
    $indexes = [System.IO.MemoryStream]::new()
    $products = [System.IO.MemoryStream]::new()
    $indexWriter = [System.IO.BinaryWriter]::new($indexes)
    $productWriter = [System.IO.BinaryWriter]::new($products)
    try {
        $productCount = 0
        foreach ($vendor in $Vendors.Values) {
            $indexWriter.Write([uint32]$vendor.Id)
            $indexWriter.Write([uint32]$strings.Position)
            $indexWriter.Write([uint32]$productCount)
            $indexWriter.Write([uint32]$vendor.Products.Count)
            $bytes = $utf8.GetBytes($vendor.Name)
            $strings.Write($bytes, 0, $bytes.Length)
            $strings.WriteByte(0)
            foreach ($product in $vendor.Products.GetEnumerator()) {
                $productWriter.Write([uint32]$product.Key)
                $productWriter.Write([uint32]$strings.Position)
                $bytes = $utf8.GetBytes($product.Value)
                $strings.Write($bytes, 0, $bytes.Length)
                $strings.WriteByte(0)
                ++$productCount
            }
        }
        $poolOffset = 32L + $indexes.Length + $products.Length
        if ($poolOffset + $strings.Length -gt [uint32]::MaxValue) {
            throw 'USB database exceeds the binary format size limit.'
        }
        $file = [System.IO.File]::Create($Path)
        $writer = [System.IO.BinaryWriter]::new($file)
        try {
            $writer.Write([byte[]](67, 85, 83, 66, 73, 68, 83, 0))
            $writer.Write([uint32]1)
            $writer.Write([uint32]$Vendors.Count)
            $writer.Write([uint32]$productCount)
            $writer.Write([uint32]$poolOffset)
            $writer.Write([uint32]$strings.Length)
            $writer.Write([uint32]0)
            foreach ($stream in @($indexes, $products, $strings)) {
                $stream.Position = 0
                $stream.CopyTo($file)
            }
        } finally {
            $writer.Dispose()
            $file.Dispose()
        }
    } finally {
        $indexWriter.Dispose()
        $productWriter.Dispose()
        $indexes.Dispose()
        $products.Dispose()
        $strings.Dispose()
    }
}

function Update-UsbIds([string]$Path) {
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Invoke-WebRequest -Uri 'https://usb-ids.gowdy.us/usb.ids' `
            -OutFile $temporary -TimeoutSec 60 -MaximumRedirection 0
        $null = Read-UsbIds $temporary
        $null = Get-UsbIdsDate $temporary
        [System.IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary
        }
    }
}
