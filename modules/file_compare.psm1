function Sync-FileIfChanged_hash {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourcePath,

        [Parameter(Mandatory=$true)]
        [string]$TargetPath
    )

    # 1. Check if source exists
    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source file not found: $SourcePath"
        return
    }

    # 2. If target doesn't exist, just copy it
    if (-not (Test-Path $TargetPath)) {
        Write-Host "Target does not exist. Initializing file..." -ForegroundColor Cyan
        Copy-Item -Path $SourcePath -Destination $TargetPath -Force
        return
    }

    # 3. Compare Hashes
    $sourceHash = (Get-FileHash -Path $SourcePath).Hash
    $targetHash = (Get-FileHash -Path $TargetPath).Hash

    if ($sourceHash -ne $targetHash) {
        Write-Host "Changes detected! Updating target file..." -ForegroundColor Yellow
        try {
            Copy-Item -Path $SourcePath -Destination $TargetPath -Force
            Write-Host "Sync successful." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to copy file: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Files are identical. No action needed." -ForegroundColor Gray
    }
}


function Sync-FileIfChanged_contentbased {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourcePath,

        [Parameter(Mandatory=$true)]
        [string]$TargetPath
    )

    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source file not found: $SourcePath"
        return
    }

    if (-not (Test-Path $TargetPath)) {
        Copy-Item -Path $SourcePath -Destination $TargetPath -Force
        return
    }

    # --- New Compare Logic ---
    $sourceContent = Get-Content -Path $SourcePath
    $targetContent = Get-Content -Path $TargetPath
    
    # Check if there is any difference in text lines
    $diff = Compare-Object $sourceContent $targetContent
    
    if ($null -ne $diff) {
        Write-Host "Changes detected! Updating target file..." -ForegroundColor Yellow
        try {
            Copy-Item -Path $SourcePath -Destination $TargetPath -Force
            Write-Host "Sync successful." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to copy file: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Files are identical. No action needed." -ForegroundColor Gray
    }
}

