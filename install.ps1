#requires -Version 5.1
& {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT' -or
        ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64')) {
        throw 'comls requires Windows x64.'
    }

    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\comls'
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        # Include Alpha prereleases: this project publishes automatic builds as prereleases.
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ah01/comls/releases?per_page=1'
        $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
        if (-not $release) { throw 'No published comls release was found.' }

        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        foreach ($name in @('comls.exe', 'LICENSE', 'SHA256SUMS.txt')) {
            $asset = $release.assets | Where-Object { $_.name -ceq $name }
            if (-not $asset) { throw "Release $($release.tag_name) is missing $name." }
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url `
                -OutFile (Join-Path $temporaryDirectory $name)
        }
        $checksums = Get-Content -LiteralPath (Join-Path $temporaryDirectory 'SHA256SUMS.txt')
        foreach ($name in @('comls.exe', 'LICENSE')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $temporaryDirectory $name) -Algorithm SHA256).Hash
            if ($checksums -inotcontains "$hash  $name") { throw "Checksum verification failed for $name." }
        }

        New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
        foreach ($name in @('LICENSE', 'comls.exe')) {
            Copy-Item -LiteralPath (Join-Path $temporaryDirectory $name) -Destination $installDirectory -Force
        }

        # Preserve unexpanded entries such as %USERPROFILE% in the user PATH.
        $environment = Get-Item -LiteralPath 'HKCU:\Environment'
        $userPath = [string]$environment.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        if (-not ($userPath -split ';' | Where-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $installDirectory
        })) {
            $newPath = ($userPath.TrimEnd(';') + ';' + $installDirectory).TrimStart(';')
            Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name Path -Value $newPath -Type ExpandString
        }
        if (-not ($env:Path -split ';' | Where-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $installDirectory
        })) {
            $env:Path = $env:Path.TrimEnd(';') + ';' + $installDirectory
        }
        Write-Host "Installed comls $($release.tag_name) to $installDirectory"
        Write-Host 'Run comls --help. Other terminals may need a sign-out/sign-in to refresh PATH.'
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}
