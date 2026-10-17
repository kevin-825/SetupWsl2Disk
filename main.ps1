
Import-Module $(Join-Path $PSScriptRoot "modules\core.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_basic.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_check.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_config.psm1") 
Import-Module $(Join-Path $PSScriptRoot "modules\file_compare.psm1") -Force

function Main {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$f = "conf0.json",
        [switch]$genBashScript
    )

    process {
        Assert-Administrator -ScriptPath $PSCommandPath
        Invoke-WslVhdxAttachmentManager -Action Attach
        Write-Host "[INFO] Starting WSL2 Disk Orchestration..." -ForegroundColor Cyan
        CheckInitializeEmptyDisk -ConfigFileName "$f"

        Mount-Wsl2Disks -ConfigFileName "$f"

        if ($genBashScript) {
            Generate-AliasScript -ConfigFileName "$f"
            $localFile  = ".\.bash_aliases_1"
            $targetFile1 = "\\wsl$\Ubuntu\home\kevin\.bash_aliases_1"
            Sync-FileIfChanged_contentbased -SourcePath $localFile -TargetPath $targetFile1
        }

        $scriptWinPath = Join-Path $PSScriptRoot "sh-scripts\last_step.sh"
        $scriptLinuxPath = Translate-WinPath2LinuxPath -WinPath $scriptWinPath
        $wslUser = (wsl whoami).Trim()
        & wsl --user root --exec bash $scriptLinuxPath $wslUser
        
        Write-Host "[INFO] Workflow completed successfully." -ForegroundColor Green
    }
}

# --- Script Entry Point Guard ---
# Ensures Main() runs automatically only when executed directly from the terminal
if ($MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    Main @args
    wsl.exe --cd ~
}
