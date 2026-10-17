<#
.SYNOPSIS
    Discovery and inspection script for physical disks and VHDX virtual disks.
    Integrates with modules\core_config.psm1 to read vhd_srcs.json.
#>

$modulePath = Join-Path $PSScriptRoot "modules\core.psm1"
Import-Module $modulePath -Force

Import-Module .\modules\core_config.psm1 -Force
Import-Module .\modules\core_basic.psm1 -Force





Assert-Administrator -ScriptPath $PSCommandPath


Read-WslVhdxSources
# 1. Initialize environment (creates directory & base config if missing)
Initialize-WslHostEnvironment

Invoke-WslVhdxAttachmentManager -Action Detach

Set-WslDiskOnlineStatus -DiskNumber 2 -On
Set-WslDiskOnlineStatus -DiskNumber 2 -Off
Set-WslDiskOnlineStatus -DiskNumber 2 

Invoke-WslVhdxAttachmentManager -Action Attach
  #foreach ($e in $array){
  #  Write-Host "e: $e"
  #}

$configEntry = Get-WslDiskConfEntry -DiskNumber 1 -PartsToMnt @(1)

Generate-Wsl2DisksConfig conf3.json
Mount-Wsl2Disks conf3.json

$disk = Get-Disk -Number 6 -ErrorAction SilentlyContinue

$disk.BusType

