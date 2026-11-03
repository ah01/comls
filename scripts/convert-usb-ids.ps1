#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InputPath = (Join-Path $PSScriptRoot '..\data\usb.ids'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\build\usb_ids.bin'),
    [string]$MetadataPath = (Join-Path $PSScriptRoot '..\build\usb_ids_metadata.h')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usb-ids.ps1')
$vendors = Read-UsbIds $InputPath
$date = Get-UsbIdsDate $InputPath
Write-UsbIdsBinary $vendors $OutputPath
[System.IO.File]::WriteAllText($MetadataPath,
    "#define COMLS_USB_IDS_DATE L`"$date`"`n", [System.Text.UTF8Encoding]::new($false))
