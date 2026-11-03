#requires -Version 7.0
Set-StrictMode -Version Latest

function Assert-RaspberryPiName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\x00-\x1f\x7f]') {
        throw 'Invalid Raspberry Pi product description.'
    }
}

function Read-RaspberryPiTable([string]$Path) {
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString([System.IO.File]::ReadAllBytes($Path)).TrimStart([char]0xfeff)
    if ([regex]::Matches($text, '(?m)^Vendor-ID = 0x2E8A[ \t]*\r?$').Count -ne 1) {
        throw 'Raspberry Pi source must identify vendor 0x2E8A exactly once.'
    }
    $products = [System.Collections.Generic.SortedDictionary[int, string]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $inTable = $false
    $separator = $false
    foreach ($rawLine in $text.Split("`n")) {
        $line = $rawLine.Trim()
        if ($line -eq '| Product ID | Company | Product Description | Product link |') {
            if ($inTable) { throw 'Duplicate Raspberry Pi assignment table.' }
            $inTable = $true
            continue
        }
        if (-not $inTable) { continue }
        if (-not $separator) {
            if ($line -notmatch '^\|\s*-+\s*\|\s*-+\s*\|\s*-+\s*\|\s*-+\s*\|$') {
                throw 'Invalid Raspberry Pi assignment table header.'
            }
            $separator = $true
            continue
        }
        if ($line -eq '' -or $line -eq '|') { continue }
        if ($line -match '^\|\s*\*\*[^|]+\*\*\s*\|\s*\|\s*\|\s*\|$') { continue }
        if ($line -notmatch '^\|\s*0x([0-9a-fA-F]{4})\s*\|([^|]*)\|([^|]*)\|([^|]*?)(?:\|)?$') {
            throw "Invalid Raspberry Pi assignment row: $line"
        }
        $id = [Convert]::ToInt32($Matches[1], 16)
        $company = $Matches[2].Trim()
        $name = $Matches[3].Trim()
        if (-not $seen.Add($id)) { throw "Duplicate Raspberry Pi PID: $($id.ToString('x4'))." }
        if ($company -match '^(?i:Reserved)(?:\s|$)' -or $name -eq '') { continue }
        Assert-RaspberryPiName $name
        $products.Add($id, $name)
    }
    if (-not $separator -or $products.Count -eq 0) {
        throw 'Raspberry Pi source contains no usable assignment table.'
    }
    return ,$products
}

function Read-RaspberryPiSnapshot([string]$Path) {
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $jsonOptions = @{ AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $jsonOptions.DateKind = 'String'
    }
    $text = $utf8.GetString([System.IO.File]::ReadAllBytes($Path)).TrimStart([char]0xfeff)
    $snapshot = ConvertFrom-Json -InputObject $text @jsonOptions
    if ($snapshot -isnot [System.Collections.IDictionary] -or
        $snapshot['Repository'] -cne 'raspberrypi/usb-pid' -or
        $snapshot['Path'] -cne 'Readme.md' -or
        $snapshot['Commit'] -isnot [string] -or
        $snapshot['Commit'] -cnotmatch '^[0-9a-f]{40}\z' -or
        $snapshot['Timestamp'] -isnot [string]) {
        throw 'Invalid Raspberry Pi snapshot provenance.'
    }
    $timestamp = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($snapshot['Timestamp'], 'yyyy-MM-ddTHH:mm:ssZ',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$timestamp)) {
        throw 'Invalid Raspberry Pi source timestamp.'
    }
    if ($snapshot['Products'] -isnot [array] -or $snapshot['Products'].Count -eq 0) {
        throw 'Raspberry Pi snapshot contains no products.'
    }
    $products = [System.Collections.Generic.SortedDictionary[int, string]]::new()
    foreach ($product in $snapshot['Products']) {
        if ($product -isnot [System.Collections.IDictionary] -or
            $product['Id'] -isnot [string] -or $product['Id'] -cnotmatch '^[0-9a-f]{4}\z' -or
            $product['Name'] -isnot [string]) {
            throw 'Invalid Raspberry Pi snapshot product.'
        }
        $id = [Convert]::ToInt32($product['Id'], 16)
        Assert-RaspberryPiName $product['Name']
        if ($products.ContainsKey($id)) { throw 'Duplicate Raspberry Pi snapshot PID.' }
        $products.Add($id, $product['Name'])
    }
    return [pscustomobject]@{
        Commit = $snapshot['Commit']
        Date = $timestamp.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        Products = $products
    }
}

function Update-RaspberryPiSnapshot([string]$Path) {
    $token = [Guid]::NewGuid().ToString('N')
    $readme = "$Path.$token.readme.tmp"
    $temporary = "$Path.$token.tmp"
    try {
        $commits = @(Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/raspberrypi/usb-pid/commits?path=Readme.md&per_page=1' `
            -TimeoutSec 60 -MaximumRedirection 0)
        if ($commits.Count -ne 1 -or $commits[0].sha -isnot [string] -or
            $commits[0].sha -cnotmatch '^[0-9a-f]{40}\z') {
            throw 'Invalid Raspberry Pi source revision response.'
        }
        $sha = $commits[0].sha
        $sourceTimestamp = $commits[0].commit.committer.date
        if ($null -eq $sourceTimestamp) { throw 'Missing Raspberry Pi source timestamp.' }
        $timestamp = ([datetimeoffset]$sourceTimestamp).UtcDateTime.ToString(
            'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/raspberrypi/usb-pid/$sha/Readme.md" `
            -OutFile $readme -TimeoutSec 60 -MaximumRedirection 0
        $products = Read-RaspberryPiTable $readme
        $snapshot = [ordered]@{
            Repository = 'raspberrypi/usb-pid'
            Path = 'Readme.md'
            Commit = $sha
            Timestamp = $timestamp
            Products = @($products.GetEnumerator() | ForEach-Object {
                [ordered]@{ Id = $_.Key.ToString('x4'); Name = $_.Value }
            })
        }
        [System.IO.File]::WriteAllText($temporary,
            (($snapshot | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
        $null = Read-RaspberryPiSnapshot $temporary
        [System.IO.File]::Move($temporary, $Path, $true)
    } finally {
        foreach ($file in @($readme, $temporary)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
        }
    }
}

function Merge-RaspberryPiProducts($Vendors, $Snapshot) {
    if (-not $Vendors.ContainsKey(0x2e8a)) {
        $Vendors.Add(0x2e8a, [pscustomobject]@{
            Id = 0x2e8a
            Name = 'Raspberry Pi'
            Products = [System.Collections.Generic.SortedDictionary[int, string]]::new()
        })
    }
    $products = $Vendors[0x2e8a].Products
    foreach ($product in $Snapshot.Products.GetEnumerator()) {
        if (-not $products.ContainsKey($product.Key)) {
            $products.Add($product.Key, $product.Value)
        }
    }
}

function Update-UsbDatabases([string]$UsbPath, [string]$RaspberryPiPath) {
    $token = [Guid]::NewGuid().ToString('N')
    $files = @($UsbPath, $RaspberryPiPath) | ForEach-Object {
        [pscustomobject]@{
            Path = $_
            Staged = "$_.$token.tmp"
            Backup = "$_.$token.backup.tmp"
            Existed = [System.IO.File]::Exists($_)
            Published = $false
        }
    }
    $completed = $false
    try {
        Update-UsbIds $files[0].Staged
        Update-RaspberryPiSnapshot $files[1].Staged
        foreach ($file in $files) {
            if ($file.Existed) { [System.IO.File]::Copy($file.Path, $file.Backup) }
        }
        try {
            foreach ($file in $files) {
                [System.IO.File]::Move($file.Staged, $file.Path, $true)
                $file.Published = $true
            }
            $completed = $true
        } catch {
            $failure = $_
            foreach ($file in $files) {
                if (-not $file.Published) { continue }
                if ($file.Existed) {
                    [System.IO.File]::Move($file.Backup, $file.Path, $true)
                } else {
                    [System.IO.File]::Delete($file.Path)
                }
                $file.Published = $false
            }
            throw $failure
        }
    } finally {
        foreach ($file in $files) {
            if ([System.IO.File]::Exists($file.Staged)) { [System.IO.File]::Delete($file.Staged) }
            # Keep the backup if a filesystem error prevented rollback.
            if ($completed -or -not $file.Published) {
                if ([System.IO.File]::Exists($file.Backup)) {
                    [System.IO.File]::Delete($file.Backup)
                }
            }
        }
    }
}
