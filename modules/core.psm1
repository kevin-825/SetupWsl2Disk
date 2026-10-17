#core.psm1
function Get-DiskNumber {
    <#
    .SYNOPSIS
        Takes a serial number and returns the raw disk number integer.
    .DESCRIPTION
        Enforces strict uniqueness. Returns just the disk number directly. 
        If multiple disks share the serial number, it halts and prints conflicting details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName =$true)]
        [Alias('Serial', 'ID')]
        [string]$SerialNumber
    )

    process {
        try {
            $cleanSerial =$SerialNumber.Trim()
            
            [array]$disks = @(Get-Disk -ErrorAction Stop | Where-Object {
                $_.SerialNumber -and ($_.SerialNumber.Trim() -eq $cleanSerial) 
            })

            # 2. If no match found by SerialNumber, try matching by UniqueId (Virtual / MsftVHD disks)
            if (-not $disks -or $disks.Count -eq 0) {
                $disks = @(Get-Disk -ErrorAction Stop | Where-Object {
                    $_.UniqueId -and ($_.UniqueId.Trim() -eq $cleanSerial)
                })
            }

            if ($disks.Count -eq 1) {
                # Return the raw disk number directly as an integer
                return [uint32]$disks[0].Number
            }
            elseif ($disks.Count -gt 1) {
                # Multiple disks found: Print info and halt
                $conflictSummary = ($disks | ForEach-Object { 
                    "  - DiskNumber: $($_.Number) | Name: $($_.FriendlyName) | Size: $([math]::Round($_.Size / 1GB, 2)) GB" 
                }) -join "`n"
                
                throw "FATAL: Found $($disks.Count) disks using this serial number '$cleanSerial'. Conflicting disks:`n$conflictSummary"
            }
            else {
                throw "FATAL: No disk found matching serial number: '$cleanSerial'"
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}

function Get-WslMountLabel {
    <#
    .SYNOPSIS
        Generates a WSL2 mount label for a specific disk partition based on disk type,
        disk number, and total partition count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber,

        [Parameter(Mandatory = $true)]
        [int[]]$PartsToMnt,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PhysicalDisk", "MsftVHD", "RamDisk")]
        [string]$DiskType
    )

    process {
        # 1. Fetch live disk details for path resolution (if MsftVHD)
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if (-not $disk) {
            Write-Warning "Disk number $DiskNumber not found in the live system."
            return $null
        }

        # 2. Determine $nameBase based on DiskType
        $nameBase = switch ($DiskType) {
            "PhysicalDisk" { 
                "disk$($DiskNumber)" 
            }
            "RamDisk"      { 
                "ramdisk$($DiskNumber)" 
            }
            "MsftVHD"      { 
                $vhdPath = $disk.Location
                if ($vhdPath) {
                    $fileName = Split-Path -Leaf $vhdPath
                    # Strip .vhdx or .vhd extension case-insensitively
                    $fileName -replace '\.(vhdx|vhd)$', ''
                } else {
                    "vhd" # Fallback if path is missing
                }
            }
        }
        # Create an ordered hashtable to store partition-to-label mappings
        $part = [ordered]@{}
        $totalParts = $PartsToMnt.Count
        foreach ($partNum in $PartsToMnt) {
            $partLable = if ($totalParts -gt 1) {
                "$($nameBase)p$($partNum)" 
            }
            else {
                "$($nameBase)"
            }
            $part["$partNum"] = $partLable
        }
        return $part
    }
}

function Mount-Wsl2Disks {
    <#
    .SYNOPSIS
        Reads a WSL2 disk configuration JSON file and mounts all configured 
        disks and their partitions into WSL2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFileName = "conf0.json"
    )

    process {
        # 1. Read the configuration entries from the JSON file
        $configData = Read-Wsl2DisksConfig -ConfigFileName $ConfigFileName
        if (-not $configData) {
            Write-Warning "No configuration data found in '$ConfigFileName'."
            return
        }

        # Handle both wrapped objects ({ Wsl2DisksConf: [...] }) and raw arrays
        $entries = if ($configData.PSObject.Properties['Wsl2DisksConf']) {
            $configData.Wsl2DisksConf
        } else {
            $configData
        }

        if (-not $entries -or $entries.Count -eq 0) {
            Write-Warning "Configuration file '$ConfigFileName' is empty."
            return
        }

        Write-Host "`n[INFO] Starting WSL2 disk mounting from '$ConfigFileName'..." -ForegroundColor Cyan

        # 2. Loop through each configured entry
        foreach ($entry in $entries) {
            # Determine the correct identifier target for Get-DiskNumber

            # 3. Turn identifier into live disk number using your existing Get-DiskNumber function
            $diskNum = $null
            if (Get-Command "Get-DiskNumber" -ErrorAction SilentlyContinue) {
                $diskNum = Get-DiskNumber -SerialNumber $entry.Identifier
            }

            if ($null -eq $diskNum) {
                Write-Warning "Could not resolve live disk number for EntryID $($entry.EntryID) \
                     (Type: $($entry.DiskType), Target: $lookupTarget). Skipping..."
                continue
            }

            Write-Host "-> Mounting Disk Entry ID $($entry.EntryID) [Live Disk Number: $diskNum] ($($entry.DiskType))" -ForegroundColor Yellow

            # 4. Loop through each partition configured for this disk and mount into WSL2
            foreach ($part in $entry.PartsToMnt.PSObject.Properties ) {
                try {
                    # Execute the native WSL2 mount command for the specific physical drive and partition
                    $partNum = $part.Name
                    $pLabel = $part.Value
                    Write-Host "Partition: $partNum -> Label: $pLabel"

                    $PhysDrvPath = "\\.\PHYSICALDRIVE$($diskNum)"
                    
                    #Write-Host "   Mounting Partition $partNum from $PhysDrvPath..." -NoNewline

                    # Run wsl --mount command
                    & wsl --mount $PhysDrvPath --name $pLabel --partition $partNum --options "noatime"
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " [SUCCESS]" -ForegroundColor Green
                    } else {
                        Write-Host " [FAILED / ALREADY MOUNTED]" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Warning "Error mounting partition $partNum on Disk $($diskNum): $_"
                }
            }
        }

        Write-Host "`n[SUCCESS] Completed WSL2 disk mounting process!" -ForegroundColor Green
    }
}




