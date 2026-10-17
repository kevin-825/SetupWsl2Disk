<#
.SYNOPSIS
    Core configuration helper module for WSL2 disk management.
    All configuration files are strictly isolated within HostConfDir.
#>

# 1. Dynamic machine-specific path resolution
$systemUuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID
$platform   = "$($env:COMPUTERNAME)_$($systemUuid)"
$script:HostConfDir = Join-Path $PSScriptRoot "..\configs\$platform"

# Centralized VHDX sources path
$script:ConfigsRootDir = Join-Path $PSScriptRoot "..\configs"
$script:VhdSrcsConfigPath = Join-Path $script:ConfigsRootDir "vhd_srcs.json"


function Initialize-WslHostEnvironment {
    <#
    .SYNOPSIS
        Initializes the machine-specific directory and creates a default config file by name.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigFileName = "conf0.json"
    )

    # Ensure host configuration directory exists
    if (-not (Test-Path -Path $script:HostConfDir)) {
        New-Item -ItemType Directory -Path $script:HostConfDir -Force | Out-Null
        Write-Host "[INIT] Created host configuration directory: $script:HostConfDir" -ForegroundColor Cyan
    }

    $targetPath = Join-Path $script:HostConfDir $ConfigFileName

    # Initialize file skeleton if missing
    if (-not (Test-Path -Path $targetPath)) {
        $initialData = [PSCustomObject]@{
            Wsl2DisksConf = @()
        }
        $initialData | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding utf8
        Write-Host "[INIT] Initialized config file: $ConfigFileName" -ForegroundColor Green
    } else {
        Write-Host "[INIT] Verified config file: $ConfigFileName" -ForegroundColor DarkGray
    }

    # Ensure shared configs root exists for vhd_srcs.json
    if (-not (Test-Path -Path $script:ConfigsRootDir)) {
        New-Item -ItemType Directory -Path $script:ConfigsRootDir -Force | Out-Null
    }
    if (-not (Test-Path -Path $script:VhdSrcsConfigPath)) {
        $initialVhdSrcs = [PSCustomObject]@{ vhdx_srcs = @() }
        $initialVhdSrcs | ConvertTo-Json -Depth 10 | Set-Content -Path $script:VhdSrcsConfigPath -Encoding utf8
    }
}


function Read-Wsl2DisksConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigFileName = "conf0.json"
    )

    $targetPath = Join-Path $script:HostConfDir $ConfigFileName

    if (-not (Test-Path -Path $targetPath)) {
        throw "Config file '$ConfigFileName' not found in $script:HostConfDir. Run Initialize-WslHostEnvironment first."
    }

    try {
        $rawJson = Get-Content -Path $targetPath -Raw -ErrorAction Stop
        $config = $rawJson | ConvertFrom-Json -ErrorAction Stop
        return @($config.Wsl2DisksConf)
    }
    catch {
        throw "Failed to read $($ConfigFileName): $_"
    }
}


function Write-Wsl2DisksConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigFileName = "conf0.json",

        [Parameter(Mandatory = $true)]
        [array]$Wsl2DisksConfData
    )

    $targetPath = Join-Path $script:HostConfDir $ConfigFileName

    # Ensure the parent configuration directory exists
    if (-not (Test-Path -Path $script:HostConfDir)) {
        New-Item -ItemType Directory -Path $script:HostConfDir -Force | Out-Null
    }

    try {
        $config = [PSCustomObject]@{
            Wsl2DisksConf = $Wsl2DisksConfData
        }

        $jsonOutput = $config | ConvertTo-Json -Depth 10 -ErrorAction Stop
        Set-Content -Path $targetPath -Value $jsonOutput -Encoding utf8 -ErrorAction Stop
    }
    catch {
        throw "Failed to write $($ConfigFileName): $_"
    }
}


function Read-WslVhdxSources {
    <#
    .SYNOPSIS
        Reads vhd_srcs.json, resolves directories (scanning for .vhdx files) and direct file paths,
        and returns a unified array of absolute VHDX file paths.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = $script:VhdSrcsConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath)) { 
        return @() 
    }

    try {
        
        $rawJson = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        $config = $rawJson | ConvertFrom-Json -ErrorAction Stop
        $rawEntries = @($config.vhdx_srcs)

        $resolvedVhdxFiles = [System.Collections.Generic.List[string]]::new()
        
        foreach ($entry in $rawEntries) {
            
            if (-not $entry) { continue }

            # Expand environment variables or relative paths if needed
            $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($entry)

            if (Test-Path -Path $resolvedPath -PathType Leaf) {
                # Case A: It's a direct file path
                if ($resolvedPath -like "*.vhdx") {
                    if (-not $resolvedVhdxFiles.Contains($resolvedPath)) {
                        $resolvedVhdxFiles.Add($resolvedPath)
                    }
                }
            }
            elseif (Test-Path -Path $resolvedPath -PathType Container) {
                # Case B: It's a directory, scan for .vhdx files inside it
                $files = Get-ChildItem -Path $resolvedPath -Filter "*.vhdx" -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    if (-not $resolvedVhdxFiles.Contains($file.FullName)) {
                        $resolvedVhdxFiles.Add($file.FullName)
                    }
                }
            }
            else {
                Write-Warning "VHDX source entry does not exist or is invalid: $entry"
            }
        }

        return $resolvedVhdxFiles.ToArray()
    }
    catch {
        throw "Failed to read or resolve vhdx_srcs: $_"
    }
}


function Get-WslDiskConfEntry {
    <#
    .SYNOPSIS
        Queries the live system for a specified disk number and partition list,
        classifying the disk into RamDisk, PhysicalDisk, or MsftVHD, and returns 
        a structured configuration object with the new Path property.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber,

        [Parameter(Mandatory = $true)]
        [int[]]$PartsToMnt
    )

    process {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if (-not $disk) {
            Write-Warning "Disk number $DiskNumber not found in the live system."
            return $null
        }

        # 1. Classify Disk Type and resolve Path
        $diskType = "PhysicalDisk"
        $pathField = ""
        $identifier = $disk.SerialNumber

        if ($disk.FriendlyName -like "*RAM Disk*" -or $disk.FriendlyName -like "*RAMDisk*") {
            $diskType = "RamDisk"
            $pathField = ""
            $identifier = $disk.SerialNumber
        }
        elseif ($disk.BusType -eq 'File Backed Virtual' -or $disk.Bus -eq 'Virtual' -or $disk.Path -like "*.vhdx*" -or $disk.Path -like "*.vhd*") {
            $diskType = "MsftVHD"
            $pathField = $disk.location
            $identifier = $disk.UniqueId
        }

        # 2. Format disk size string cleanly
        $sizeGb = "{0:N0} GB" -f ($disk.Size / 1GB)
        if ($disk.Size -lt 1GB) {
            $sizeGb = "{0:N2} MB" -f ($disk.Size / 1MB)
        }

        # Create an ordered hashtable to store partition-to-label mappings
        $parts = Get-WslMountLabel -DiskNumber $DiskNumber -PartsToMnt $PartsToMnt -DiskType $DiskType

        # 3. Return standardized configuration entry object matching your schema
        [PSCustomObject]@{
            EntryID    = 0
            DiskType   = $diskType
            Identifier = $identifier
            PartsToMnt = $parts
            DiskSize   = $sizeGb
            DiskName   = $disk.FriendlyName
            DrvLetter  = ""
            Path       = $pathField
        }
    }
}



function Generate-Wsl2DisksConfig {
    <#
    .SYNOPSIS
        Interactively prompts for disk selections, accumulates all configuration entries,
        and completely overwrites the JSON config file with the fresh batch.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigFileName = "conf0.json"
    )

    process {
        # 1. Prompt user for selections (e.g., "5[1,3] 2[1]")
        $selections = Read-WslUserDiskSelection

        if (-not $selections -or $selections.Count -eq 0) {
            Write-Warning "No selections were provided."
            return
        }

        # 2. Accumulate new entries in a list, starting EntryID from 0
        $newEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
        $entryId = 0

        foreach ($sel in $selections) {
            $entry = Get-WslDiskConfEntry -DiskNumber $sel.DiskNumber -PartsToMnt $sel.Partitions

            if ($entry) {
                $entry.EntryID = "$entryId"
                $newEntries.Add($entry)
                $entryId++
            }
        }

        # 3. Overwrite the JSON file completely with the fresh batch
        if ($newEntries.Count -gt 0) {
            Write-Wsl2DisksConfig -ConfigFileName $ConfigFileName -Wsl2DisksConfData $newEntries.ToArray()

            Write-Host "`n[SUCCESS] Successfully overwrote '$ConfigFileName' with $($newEntries.Count) new configuration entries!" -ForegroundColor Green
        }
        else {
            Write-Warning "No valid entries were collected to write."
        }
    }
}