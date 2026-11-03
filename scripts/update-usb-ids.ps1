#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usb-ids.ps1')
$path = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\usb.ids'))
Update-UsbIds $path
Write-Host 'Updated data\usb.ids. Review and commit the snapshot, then rebuild.'
