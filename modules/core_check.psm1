
function Translate-WinPath2LinuxPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName', 'Path')]
        [string[]]$WinPath
    )

    process {
        foreach ($path in $WinPath) {
            # 1. Resolve relative paths (like "." or "..\foo") to absolute Windows paths
            $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)

            # 2. Try using WSL's native 'wslpath' utility (handles custom mounts & distros perfectly)
            try {
                $linuxPath = & wsl.exe wslpath -u "$resolvedPath" 2>&1
                if ($LASTEXITCODE -eq 0 -and $linuxPath) {
                    $linuxPath.Trim()
                    continue
                }
            }
            catch {
                # Fallback to manual string conversion if wslpath encounters an issue
            }

            # 3. Pure PowerShell Fallback (C:\Foo\Bar -> /mnt/c/Foo/Bar)
            if ($resolvedPath -match '^[a-zA-Z]:') {
                $drive = $resolvedPath.Substring(0, 1).ToLower()
                $remainder = $resolvedPath.Substring(2).Replace('\', '/')
                "/mnt/$drive$remainder"
            } 
            else {
                # Generic fallback for UNC or non-standard paths
                $resolvedPath.Replace('\', '/')
            }
        }
    }
}

function Bare_mountDisk {
    <#
    .SYNOPSIS
        Bare-mounts a disk into WSL2 based on whether it is a virtual VHDX or a physical/RAM drive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$entry,

        [Parameter(Mandatory = $true)]
        [int]$diskNum
    )

    if ($entry.DiskType -eq "MsftVHD") {
        if (-not $entry.Path) {
            Write-Error "   [ERROR] Virtual disk EntryID [$($entry.EntryID)] is missing the 'Path' field."
            return
        }
        Write-Host "   Bare mounting VHD path: $($entry.Path)"
        & wsl --mount --vhd $entry.Path --bare
    }
    else {
        $physDrivePath = "\\.\PHYSICALDRIVE$diskNum"
        Write-Host "   Bare mounting physical/RAM drive: $physDrivePath"
        & wsl --mount $physDrivePath --bare
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "   [INFO] Bare mount command exit code: $LASTEXITCODE (Disk may already be attached)." -ForegroundColor Gray
    }
}

function CheckInitializeEmptyDisk {
    <#
    .SYNOPSIS
        Inspects disks from the WSL2 configuration file. If a disk is empty (RAW or zero partitions),
        it bare-mounts it (using Path for VHDs or PhysicalDrive path for physical/RAM disks)
        and runs ./sh-scripts/initialize_empty_disk.sh inside WSL as root user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigFileName = "conf0.json"
    )

    process {
        # 1. Read configuration data
        $configData = Read-Wsl2DisksConfig -ConfigFileName $ConfigFileName
        if (-not $configData) {
            Write-Warning "No configuration data found in '$ConfigFileName'."
            return
        }

        # Handle wrapped vs raw arrays
        $entries = if ($configData.PSObject.Properties['Wsl2DisksConf']) {$configData.Wsl2DisksConf
        } else {
            $configData
        }

        if (-not $entries -or $entries.Count -eq 0) {
            Write-Warning "Configuration file '$ConfigFileName' is empty."
            return
        }

        Write-Host "`n[INFO] Inspecting disk states from '$ConfigFileName'..." -ForegroundColor Cyan
        # Resolve local script path and translate to WSL Linux path
        $scriptWinPath = Join-Path $PSScriptRoot "..\sh-scripts\initialize_empty_disk.sh"
        if (-not (Test-Path $scriptWinPath)) {
            Write-Error "Initialization script not found at: $scriptWinPath"
            continue
        }

        $scriptLinuxPath = Translate-WinPath2LinuxPath -WinPath $scriptWinPath
        # 2. Loop through each configured entry
        foreach ($entry in $entries) {
            $diskNum = $null
            if (Get-Command "Get-DiskNumber" -ErrorAction SilentlyContinue) {
                # Determine target identifier (Path for VHDX, Identifier for Physical/RAM)
                $SerialNum = $entry.Identifier
                $diskNum = Get-DiskNumber -SerialNumber $SerialNum
            }

            if ($null -eq $diskNum) {
                Write-Warning "Could not resolve live disk for EntryID [$($entry.EntryID)]. Skipping..."
                continue
            }

            # 3. Inspect live disk partition status and style
            $disk = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
            $partitions = @(Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue)

            $isEmpty = $false
            if ((-not $disk) -or ($disk.PartitionStyle -in @('RAW', 'Unknown')) -or ($partitions.Count -eq 0)) {
                $isEmpty = $true
            }

            # 4. Action: Bare mount and initialize if empty, or report normal if not empty
            if ($isEmpty) {
                Write-Host "-> EntryID [$($entry.EntryID)] [Disk $diskNum] is EMPTY (RAW / 0 partitions). Preparing bare mount..." -ForegroundColor Yellow

                # Perform conditional bare mount based on DiskType
                Bare_mountDisk -entry $entry -diskNum $diskNum

                # Execute initialization script inside WSL2 as root user (--user root)
                Write-Host "   Running initialization script as root..." -ForegroundColor Cyan
                & wsl --user root --exec bash $scriptLinuxPath $($entry.Identifier) $($entry.DiskType)

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "   [SUCCESS] Disk $diskNum initialized successfully." -ForegroundColor Green
                } else {
                    Write-Warning "   [ERROR] Initialization script failed for Disk $diskNum."
                }
            } else {
                Write-Host "-> EntryID [$($entry.EntryID)] [Disk $diskNum] is normal, not empty ($($partitions.Count) partition(s) found)." -ForegroundColor Green
                if ($entry.DiskType -eq "RamDisk") {
                    Write-Host " Check for Ramdisk partition ..."
                    foreach ($prop in $entry.PartsToMnt.PSObject.Properties) {
                        $partNum = $prop.Name
                        wsl --unmount "\\.\PHYSICALDRIVE$($diskNum)"
                        Set-WslDiskOnlineStatus -DiskNumber $diskNum -On
                        # Inspect the file system of this specific partition
                        $targetPartition = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction SilentlyContinue
                        $targetVolume = $targetPartition | Get-Volume -ErrorAction SilentlyContinue
                        #Set-WslDiskOnlineStatus -DiskNumber $diskNum -Off
                        Write-Host " partNum:$partNum  FileSystem:$($targetVolume.FileSystemType) "
                        if ($targetVolume -and $targetVolume.FileSystemType -eq "NTFS") {
                            Write-Host "   [INFO] RamDisk Partition $partNum has NTFS file system. Preparing to reformat..." -ForegroundColor Yellow

                            # Bare-mount the disk
                            Bare_mountDisk -entry $entry -diskNum $diskNum

                            # Execute initialization script inside WSL2 as root user with 3 arguments
                            Write-Host "   Running initialization script as root with partition formatting..." -ForegroundColor Cyan
                            & wsl --user root --exec bash $scriptLinuxPath $($entry.Identifier) $($entry.DiskType) $partNum

                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "   [SUCCESS] Partition $partNum on Disk $diskNum formatted successfully." -ForegroundColor Green
                            } else {
                                Write-Warning "   [ERROR] Initialization script failed for partition $partNum on Disk $diskNum."
                            }
                        }
                    }
                }
            }
        }

        Write-Host "`n[SUCCESS] Disk health check and initialization check completed!" -ForegroundColor Cyan
    }
}



function Generate-AliasScript {
    <#
    .SYNOPSIS
        Reads a WSL2 disk configuration JSON file and generates .bash_alias_1 file
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

        Write-Host "`n[INFO] Starting generating .bash_alias_1 from '$ConfigFileName'..." -ForegroundColor Cyan
        $DockerVolumeLists=@()
        $alias_cmds=@()
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

            $diskNameShort = switch ($DiskType) {
                "PhysicalDisk" { 
                    "d$($DiskNumber)" 
                }
                "RamDisk"      { 
                    "rd$($DiskNumber)" 
                }
                "MsftVHD"      { 
                    "v$($DiskNumber)"
                }
            }

            # 4. Loop through each partition configured for this disk and mount into WSL2
            foreach ($part in $entry.PartsToMnt.PSObject.Properties ) {
                try {
                    # Execute the native WSL2 mount command for the specific physical drive and partition
                    $partNum = $part.Name
                    $pLabel = $part.Value

                    $partNameShort = if ($totalParts -gt 1) {
                        "$($diskNameShort)p$($partNum)" 
                    }
                    else {
                        "$($diskNameShort)"
                    }
                    $DockerVolumeLists += "-v /mnt/wsl/$($pLabel):/mnt/wsl/$($pLabel) \"
                    $alias_cmds += "alias cd2$($partNameShort)='cd /mnt/wsl/$($pLabel)'"
                }
                catch {
                    Write-Warning "Error generating alias cmd for partition $partNum on Disk $($diskNum): $_"
                }
                
            }
        }
        Write-Host "Creating Alias file ..."

        $aliasFile = Join-Path $PSScriptRoot "../.bash_aliases_1"
        
        "" | Set-Content $aliasFile -Encoding Ascii

        foreach ($cmd in $alias_cmds) {
            Add-Content -Encoding Ascii $aliasFile $cmd
        }
        Add-Content -Encoding Ascii $aliasFile ''
        Add-Content -Encoding Ascii $aliasFile 'dockerVolumes="\'
        foreach ($line in $DockerVolumeLists) {
            Add-Content -Encoding Ascii $aliasFile $line
        }
        Add-Content -Encoding Ascii $aliasFile '"'

        Add-Content -Encoding Ascii $aliasFile 'export dockerVolumes'
        Add-Content -Encoding Ascii $aliasFile ''

        Write-Host "Alias file created at: $aliasFile"
        Write-Host ""

        Write-Host "`n[SUCCESS] Completed generating Alias file." -ForegroundColor Green
    }
}