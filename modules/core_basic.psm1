# DiskTools.psm1
function Assert-Administrator {
    param (
        # Accept the calling script's path explicitly
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

    if (-not $isAdmin) {
        Write-Warning "Relaunching script as Administrator..."
        Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -Verb RunAs
        exit
    }
}

function Set-WslDiskOnlineStatus {
    <#
    .SYNOPSIS
        Sets a physical or virtual disk to Online or Offline status.
    .DESCRIPTION
        Takes a disk number and either the -On or -Off switch to modify the disk's state.
        Requires Administrator privileges.
    #>
    [CmdletBinding(DefaultParameterSetName = 'OnState')]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber,

        [Parameter(ParameterSetName = 'OnState')]
        [switch]$On,

        [Parameter(ParameterSetName = 'OffState')]
        [switch]$Off
    )

    process {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if (-not $disk) {
            Write-Warning "Disk number $DiskNumber not found in the system."
            return
        }

        try {
            if ($Off) {
                if ($disk.IsOffline) {
                    Write-Host "[SKIP] Disk $DiskNumber is already Offline." -ForegroundColor DarkGray
                    return
                }
                Write-Host "[OFFLINE] Setting disk $DiskNumber ($($disk.FriendlyName)) to Offline..." -ForegroundColor Yellow
                Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
                Write-Host "[SUCCESS] Disk $DiskNumber is now Offline." -ForegroundColor Green
            }
            else {
                # Default or -On switch
                if (-not $disk.IsOffline) {
                    Write-Host "[SKIP] Disk $DiskNumber is already Online." -ForegroundColor DarkGray
                    return
                }
                Write-Host "[ONLINE] Setting disk $DiskNumber ($($disk.FriendlyName)) to Online..." -ForegroundColor Cyan
                Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
                Write-Host "[SUCCESS] Disk $DiskNumber is now Online." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "Failed to update online state for disk $($DiskNumber): $_"
        }
    }
}

function Invoke-WslVhdxAttachmentManager {
    <#
    .SYNOPSIS
        Attaches or detaches VHDX virtual disk files in Windows.
    .DESCRIPTION
        Processes either a provided list of VHDX paths or automatically resolves 
        all VHDX files from vhd_srcs.json. Requires Administrator privileges.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$VhdxPaths,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Attach", "Detach")]
        [string]$Action
    )

    process {
        # Fallback to all resolved VHDX sources if no specific paths are passed
        if (-not $VhdxPaths -or $VhdxPaths.Count -eq 0) {
            Write-Host "[INFO] No specific paths provided. Loading all VHDX files from sources..." -ForegroundColor Cyan
            $VhdxPaths = Read-WslVhdxSources
        }

        if (-not $VhdxPaths -or $VhdxPaths.Count -eq 0) {
            Write-Warning "No VHDX files found to process."
            return
        }

        foreach ($path in $VhdxPaths) {
            if (-not (Test-Path -Path $path)) {
                Write-Warning "VHDX file does not exist at path: $path"
                continue
            }

            $fileName = Split-Path -Leaf $path

            # Check if this VHDX is currently attached to Windows as a disk
            $existingDisk = Get-Disk | Where-Object { 
                $_.Path -like "*$fileName*" -or $_.Location -like "*$fileName*" 
            } -ErrorAction SilentlyContinue

            try {
                if ($Action -eq "Attach") {
                    if ($existingDisk) {
                        Write-Host "[SKIP] VHDX '$fileName' is already attached (Disk Number: $($existingDisk.Number))." -ForegroundColor DarkCyan
                    } else {
                        Write-Host "[ATTACH] Mounting VHDX: $path..." -ForegroundColor Cyan
                        Mount-Vhd -Path $path -ErrorAction Stop
                        Write-Host "[SUCCESS] Successfully attached '$fileName'." -ForegroundColor Green
                    }
                }
                elseif ($Action -eq "Detach") {
                    if (-not $existingDisk) {
                        Write-Host "[SKIP] VHDX '$fileName' is not currently attached." -ForegroundColor DarkGray
                    } else {
                        Write-Host "[DETACH] Dismounting VHDX: $path (Disk Number: $($existingDisk.Number))..." -ForegroundColor Yellow
                        Dismount-Vhd -Path $path -ErrorAction Stop
                        Write-Host "[SUCCESS] Successfully detached '$fileName'." -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Error "Failed to $Action VHDX '$fileName': $_"
            }
        }
    }
}

function Read-WslUserDiskSelection {
    <#
    .SYNOPSIS
        Prompts the user for disk and partition selections in the format "5[1,3] 7[1]"
        with a customizable prompt message and returns an iterable array of objects.
    #>
    [CmdletBinding()]
    param(
        [string]$PromptMessage = "Enter disk and partition selections"
    )

    Write-Host "Format: DiskNum[Part1,Part2,...] (e.g., 5[1,3] 7[1] 1[1])" -ForegroundColor Cyan
    $inputStr = Read-Host $PromptMessage

    if (-not $inputStr) {
        Write-Warning "No input provided."
        return @()
    }

    # Regex matching pattern: digits followed by bracketed comma-separated numbers
    $pattern = '(\d+)\s*\[([\d,\s]+)\]'
    $matches = [System.Text.RegularExpressions.Regex]::Matches($inputStr, $pattern)

    if ($matches.Count -eq 0) {
        Write-Warning "No valid selections matched the expected format."
        return @()
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($match in $matches) {
        $diskNum = [int]$match.Groups[1].Value
        $rawParts = $match.Groups[2].Value
        
        # Split partition string by comma, trim whitespace, and convert to integer array
        $partitions = @($rawParts -split ',' | ForEach-Object { [int]($_.Trim()) })
        #Write-Host " diskNum:$diskNum     partitions:$partitions"
        $results.Add([PSCustomObject]@{
            DiskNumber = $diskNum
            Partitions = $partitions
        })
    }

    return $results.ToArray()
}


function Show-PartitionList {
    <#
    .SYNOPSIS
        Displays a detailed list of partitions and their properties for a given disk number,
        handling empty or RAW disks gracefully.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNum
    )

    # Force results into an array to accurately check the count
    $partitions = @(Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue)

    if ($partitions.Count -eq 0) {
        Write-Host "   [INFO] Disk $DiskNum has no partitions (RAW / Unallocated / Empty)." -ForegroundColor Yellow
        return
    }

    $partitionList = foreach ($p in $partitions) {
        $volume = $p | Get-Volume -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            "PartNum" = $p.PartitionNumber
            "DrvLtr"  = if ($p.DriveLetter) { $p.DriveLetter } else { "-" }
            "Size"    = if (Get-Command "formatDiskSize" -ErrorAction SilentlyContinue) { formatDiskSize -disk $p } else { "$([math]::round($p.Size / 1GB, 2)) GB" }
            "Label"   = if ($volume.FileSystemLabel) { $volume.FileSystemLabel } else { "" }
            "FsType"  = if ($volume.FileSystem) { $volume.FileSystem } else { "RAW/Unknown" }
            "Info"    = $p.Type
        }
    }

    # Display the results in a clean auto-sized table
    $partitionList | Format-Table -AutoSize
}
# ==========================================
# FUNCTION 1: Print Single Physical Disk Info
# ==========================================
function Show-PhysicalDiskInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-Warning "Physical disk number $DiskNumber not found."
        return
    }

    # Retrieve serial number reliably
    $serial = $disk.SerialNumber
    if (-not $serial) {
        $drive = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $DiskNumber }
        $serial = if ($drive) { $drive.SerialNumber.Trim() } else { "N/A" }
    }

    # Get partition count
    $partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    $partCount = if ($partitions) { @($partitions).Count } else { 0 }

    # Format output object
    [PSCustomObject]@{
        "Disk Number"     = $disk.Number
        "Disk Name"       = $disk.FriendlyName
        "Serial Number"   = $serial
        "Disk Size"       = "{0:N2} GB" -f ($disk.Size / 1GB)
        "Partition Style" = $disk.PartitionStyle
        "Partition Count" = $partCount
        "Status"          = if ($disk.IsOnline) { "Online" } else { "Offline" }
        "Bus Type"        = $disk.Bus
    } | Format-List 

    Show-PartitionList -DiskNum $($disk.Number) 
}

# ==========================================
# FUNCTION 2: Print Single VHDX File Info
# ==========================================
function Show-VhdxFileInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath
    )

    if (-not (Test-Path -Path $VhdxPath)) {
        Write-Warning "VHDX file not found at: $VhdxPath"
        return
    }

    $vhd = Get-Vhd -Path $VhdxPath -ErrorAction SilentlyContinue
    $fileName = Split-Path -Leaf $VhdxPath

    # Check if this VHDX is currently attached to the system as a disk
    $disk = Get-Disk | Where-Object { $_.Location -like "*$fileName*" -or $_.Path -like "*$fileName*" } -ErrorAction SilentlyContinue

    $diskNum   = if ($disk) { $disk.Number } else { "Not Attached" }
    $status    = if ($disk) { $(if ($disk.IsOnline) { "Online (Attached)" } else { "Offline (Attached)" }) } else { "Detached" }
    $partStyle = if ($disk) { $disk.PartitionStyle } else { "N/A" }
    
    $partCount = 0
    if ($disk) {
        $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        $partCount = if ($parts) { @($parts).Count } else { 0 }
    }

    $sizeGb = if ($vhd) { "{0:N2} GB" -f ($vhd.Size / 1GB) } else { "Unknown" }

    # Format output object
    [PSCustomObject]@{
        "VHDX File Name"  = $fileName
        "VHDX File Path"  = $VhdxPath
        "Disk Number"     = $diskNum
        "Disk Name"       = if ($disk) { $disk.FriendlyName } else { "Microsoft Virtual Disk" }
        "Serial Number"   = "N/A (Virtual)"
        "Disk Size"       = $sizeGb
        "Partition Style" = $partStyle
        "Partition Count" = $partCount
        "Status"          = $status
    } | Format-List

    Show-PartitionList -DiskNum $($disk.Number) 
}


# ==========================================
# FUNCTION 3: Print All Physical Disks
# ==========================================
function Show-AllPhysicalDisks {
    [CmdletBinding()]
    param()

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "       AVAILABLE PHYSICAL DISKS         " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Exclude file-backed virtual disks from the physical scan
    $physicalDisks = Get-Disk | Where-Object { 
        $_.BusType -ne 'File Backed Virtual' -and $_.BusType -ne 'Virtual' 
    } | Sort-Object Number

    if (-not $physicalDisks) {
        Write-Host "No physical disks found." -ForegroundColor Yellow
        return
    }

    foreach ($d in $physicalDisks) {
        Show-PhysicalDiskInfo -DiskNumber $d.Number
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
    }
}


# ==========================================
# FUNCTION 4: Print All VHDX Files from Sources
# ==========================================
function Show-AllVhdxFiles {
    [CmdletBinding()]
    param()

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "       AVAILABLE VHDX FILES             " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Retrieve all resolved VHDX paths (combining direct files and scanned directory contents)
    $vhdxPaths = Read-WslVhdxSources

    if (-not $vhdxPaths -or $vhdxPaths.Count -eq 0) {
        Write-Host "No VHDX files found from sources in 'configs\vhd_srcs.json'." -ForegroundColor Yellow
        return
    }

    foreach ($path in $vhdxPaths) {
        Show-VhdxFileInfo -VhdxPath $path
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
    }
}
