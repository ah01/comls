#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InputPath = (Join-Path $PSScriptRoot '..\data\usb.ids'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\build\usb_ids.bin')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usb-ids.ps1')
$vendors = Read-UsbIds $InputPath
Write-UsbIdsBinary $vendors $OutputPath
