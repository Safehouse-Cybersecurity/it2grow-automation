<#
.SYNOPSIS
    Generalize Windows Server 2025 for Proxmox template creation
.DESCRIPTION
    Cleans up the system, removes Sophos identity, and runs sysprep
.EXAMPLE
    .\Invoke-Generalization.ps1
    .\Invoke-Generalization.ps1 -SkipSysprep
#>

param(
    [switch]$SkipSophos,
    [switch]$SkipSysprep
)

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'

Write-Host "`n=== Windows Server 2025 Generalization ===" -ForegroundColor Cyan
Write-Host "IT2Grow B.V.`n" -ForegroundColor Cyan

# 1. Clean temp files
Write-Host "[1/5] Cleaning temporary files..." -ForegroundColor Yellow
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      Done" -ForegroundColor Green

# 2. Clear event logs
Write-Host "[2/5] Clearing event logs..." -ForegroundColor Yellow
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
    [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($_.LogName) 2>$null
}
Write-Host "      Done" -ForegroundColor Green

# 3. Reset network
Write-Host "[3/5] Resetting network..." -ForegroundColor Yellow
ipconfig /release *>$null
ipconfig /flushdns *>$null
Write-Host "      Done" -ForegroundColor Green

# 4. Sophos cleanup
if (-not $SkipSophos) {
    Write-Host "[4/5] Cleaning Sophos identity..." -ForegroundColor Yellow
    
    if (Test-Path "$env:ProgramData\Sophos") {
        # Stop services
        Get-Service -Name "Sophos*" -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        
        # Remove identity files
        Remove-Item "$env:ProgramData\Sophos\Management Communications System\Endpoint\Persist\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:ProgramData\Sophos\AutoUpdate\data\machine_ID.txt" -Force -ErrorAction SilentlyContinue
        
        # Clear registry
        Remove-ItemProperty "HKLM:\SOFTWARE\Sophos\Management Communications System\Endpoint" -Name "Id" -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Sophos\Management Communications System\Endpoint" -Name "Id" -Force -ErrorAction SilentlyContinue
        
        Write-Host "      Done - endpoint will re-register after clone" -ForegroundColor Green
    } else {
        Write-Host "      Sophos not installed, skipping" -ForegroundColor Gray
    }
} else {
    Write-Host "[4/5] Skipping Sophos cleanup" -ForegroundColor Gray
}

# 5. Sysprep
if (-not $SkipSysprep) {
    Write-Host "[5/5] Running sysprep..." -ForegroundColor Yellow
    Write-Host "      System will shutdown when complete..." -ForegroundColor Yellow
    Start-Process "$env:SystemRoot\System32\Sysprep\sysprep.exe" -ArgumentList "/generalize /oobe /shutdown /mode:vm" -Wait
} else {
    Write-Host "[5/5] Skipping sysprep" -ForegroundColor Gray
    Write-Host "`nCleanup complete. Run sysprep manually when ready." -ForegroundColor Green
}
