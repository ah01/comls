#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InputPath = (Join-Path $PSScriptRoot '..\data\usb.ids'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\build\usb_ids.bin'),
    [string]$MetadataPath = (Join-Path $PSScriptRoot '..\build\usb_ids_metadata.h'),
    [string]$RaspberryPiPath = (Join-Path $PSScriptRoot '..\data\raspberrypi-usb-pid.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usb-ids.ps1')
. (Join-Path $PSScriptRoot 'raspberrypi-usb-pid.ps1')
$vendors = Read-UsbIds $InputPath
$date = Get-UsbIdsDate $InputPath
$raspberryPi = Read-RaspberryPiSnapshot $RaspberryPiPath
Merge-RaspberryPiProducts $vendors $raspberryPi
Write-UsbIdsBinary $vendors $OutputPath
[System.IO.File]::WriteAllText($MetadataPath,
    ("#define COMLS_USB_IDS_DATE L`"$date`"`n" +
     "#define COMLS_RASPBERRY_PI_DATE L`"$($raspberryPi.Date)`"`n" +
     "#define COMLS_RASPBERRY_PI_COMMIT L`"$($raspberryPi.Commit)`"`n"),
    [System.Text.UTF8Encoding]::new($false))
