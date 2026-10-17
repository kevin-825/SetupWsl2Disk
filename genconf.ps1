Import-Module $(Join-Path $PSScriptRoot "modules\core.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_basic.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_check.psm1") -Force
Import-Module $(Join-Path $PSScriptRoot "modules\core_config.psm1") -Force




function Main {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$f = "conf0.json"
    )

    process {
        Assert-Administrator -ScriptPath $PSCommandPath
        
        Write-Host "[INFO] Starting WSL2 Mount Disk Configuration..." -ForegroundColor Cyan

        # 1. Initialize environment (creates directory & base config if missing)
        $ConfFileNumber=0
        $configFile="conf$($ConfFileNumber).json"
        Initialize-WslHostEnvironment -ConfigFileName $configFile

        #Invoke-WslVhdxAttachmentManager -Action Detach
        Invoke-WslVhdxAttachmentManager -Action Attach
        Show-AllPhysicalDisks
        Show-AllVhdxFiles

        Generate-Wsl2DisksConfig -ConfigFileName $configFile
        

        Write-Host "[INFO] WSL2 Mount Disk Configuration Workflow completed successfully." -ForegroundColor Green
    }
}

# --- Script Entry Point Guard ---
# Ensures Main() runs automatically only when executed directly from the terminal
if ($MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    Main @args
}
