#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usb-ids.ps1')
. (Join-Path $PSScriptRoot 'raspberrypi-usb-pid.ps1')
$path = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\usb.ids'))
$raspberryPiPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\data\raspberrypi-usb-pid.json'))
Update-UsbDatabases $path $raspberryPiPath
Write-Host 'Updated both USB database snapshots. Review and commit the snapshots, then rebuild.'
