<#
.SYNOPSIS
    Generalize Windows Server 2025 for Proxmox template creation
.DESCRIPTION
    Cleans up the system, removes Sophos identity, and runs sysprep
.EXAMPLE
    .\Prepare-Template.ps1
    .\Prepare-Template.ps1 -SkipSysprep
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
Write-Host "[1/6] Cleaning temporary files..." -ForegroundColor Yellow
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      Done" -ForegroundColor Green

# 2. Clear event logs
Write-Host "[2/6] Clearing event logs..." -ForegroundColor Yellow
wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
Write-Host "      Done" -ForegroundColor Green

# 3. Reset network
Write-Host "[3/6] Resetting network..." -ForegroundColor Yellow
ipconfig /release *>$null
ipconfig /flushdns *>$null
Write-Host "      Done" -ForegroundColor Green

# 4. Sophos cleanup
if (-not $SkipSophos) {
    Write-Host "[4/6] Cleaning Sophos identity..." -ForegroundColor Yellow
    
    $sophosServices = Get-Service -Name "Sophos*" -ErrorAction SilentlyContinue
    $sophosInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | 
                       Where-Object { $_.DisplayName -like "*Sophos*" }
    
    if ($sophosServices -or $sophosInstalled) {
        $cleaned = $false
        
        if ($sophosServices) {
            $sophosServices | Stop-Service -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        
        $persistPath = "$env:ProgramData\Sophos\Management Communications System\Endpoint\Persist"
        if (Test-Path $persistPath) {
            $items = Get-ChildItem $persistPath -ErrorAction SilentlyContinue
            if ($items) {
                Remove-Item "$persistPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "      Removed: MCS Persist folder" -ForegroundColor Gray
                $cleaned = $true
            }
        }
        
        $machineIdPath = "$env:ProgramData\Sophos\AutoUpdate\data\machine_ID.txt"
        if (Test-Path $machineIdPath) {
            Remove-Item $machineIdPath -Force -ErrorAction SilentlyContinue
            Write-Host "      Removed: machine_ID.txt" -ForegroundColor Gray
            $cleaned = $true
        }
        
        $regPath = "HKLM:\SOFTWARE\Sophos\Management Communications System\Endpoint"
        if ((Test-Path $regPath) -and (Get-ItemProperty $regPath -Name "Id" -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty $regPath -Name "Id" -Force -ErrorAction SilentlyContinue
            Write-Host "      Removed: Registry Id" -ForegroundColor Gray
            $cleaned = $true
        }
        
        $regPath64 = "HKLM:\SOFTWARE\WOW6432Node\Sophos\Management Communications System\Endpoint"
        if ((Test-Path $regPath64) -and (Get-ItemProperty $regPath64 -Name "Id" -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty $regPath64 -Name "Id" -Force -ErrorAction SilentlyContinue
            Write-Host "      Removed: Registry Id (WOW64)" -ForegroundColor Gray
            $cleaned = $true
        }
        
        if ($cleaned) {
            Write-Host "      Done - endpoint will re-register after clone" -ForegroundColor Green
        } else {
            Write-Host "      Sophos installed but no identity data found" -ForegroundColor Yellow
        }
    } else {
        Write-Host "      Sophos not installed, skipping" -ForegroundColor Gray
    }
} else {
    Write-Host "[4/6] Skipping Sophos cleanup" -ForegroundColor Gray
}

# 5. Fix AppX issues for sysprep
Write-Host "[5/6] Fixing AppX for sysprep..." -ForegroundColor Yellow

# Remove Edge using its setup.exe
$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\*\Installer\setup.exe"
)

$edgeSetup = $null
foreach ($path in $edgePaths) {
    $found = Get-Item $path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $edgeSetup = $found.FullName; break }
}

if ($edgeSetup) {
    Write-Host "      Removing Microsoft Edge..." -ForegroundColor Gray
    Start-Process -FilePath $edgeSetup -ArgumentList "--uninstall --system-level --force-uninstall" -Wait -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# Remove Edge AppX packages
Get-AppxPackage -AllUsers *MicrosoftEdge* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*Edge*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue

# Mark any remaining problematic apps as deprovisioned
$deprovisionPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
Get-AppxPackage -AllUsers | ForEach-Object {
    $keyPath = "$deprovisionPath\$($_.PackageFamilyName)"
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
}

Write-Host "      Done" -ForegroundColor Green

# 6. Sysprep
if (-not $SkipSysprep) {
    Write-Host "[6/6] Running sysprep..." -ForegroundColor Yellow
    Write-Host "      System will shutdown when complete..." -ForegroundColor Yellow
    Start-Process "$env:SystemRoot\System32\Sysprep\sysprep.exe" -ArgumentList "/generalize /oobe /shutdown /mode:vm" -Wait
} else {
    Write-Host "[6/6] Skipping sysprep" -ForegroundColor Gray
    Write-Host "`nCleanup complete. Run sysprep manually when ready." -ForegroundColor Green
}
