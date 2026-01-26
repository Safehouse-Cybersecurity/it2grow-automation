<#
.SYNOPSIS
    Generalize Windows Server 2025 for Proxmox template creation
.DESCRIPTION
    Cleans up the system, preloads regional settings, removes Sophos identity,
    normalizes Edge and runs sysprep
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
Write-Host "[1/7] Cleaning temporary files..." -ForegroundColor Yellow
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      Done" -ForegroundColor Green

# 2. Clear event logs
Write-Host "[2/7] Clearing event logs..." -ForegroundColor Yellow
wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
Write-Host "      Done" -ForegroundColor Green

# 3. Reset network
Write-Host "[3/7] Resetting network..." -ForegroundColor Yellow
ipconfig /release *>$null
ipconfig /flushdns *>$null
Write-Host "      Done" -ForegroundColor Green

# 4. Configure regional settings (EN-US UI, US-International keyboard, NL region)
Write-Host "[4/7] Configuring regional & language settings..." -ForegroundColor Yellow

try {
    # System locale (non-Unicode programs)
    Set-WinSystemLocale -SystemLocale nl-NL

    # Culture (dates, numbers, currency)
    Set-Culture nl-NL

    # Home location (Netherlands = 176)
    Set-WinHomeLocation -GeoId 176

    # Language + keyboard
    $LangList = New-WinUserLanguageList "en-US"

    # United States–International keyboard
    $LangList[0].InputMethodTips.Clear()
    $LangList[0].InputMethodTips.Add("0409:00020409")

    Set-WinUserLanguageList $LangList -Force

    # Copy to system + default user profile
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true

    # Timezone
    Set-TimeZone -Id "W. Europe Standard Time"

    Write-Host "      EN-US UI, US-International keyboard, NL region applied" -ForegroundColor Green
}
catch {
    Write-Host "      Failed to configure regional settings: $_" -ForegroundColor Red
}

# 5. Sophos cleanup
if (-not $SkipSophos) {
    Write-Host "[5/7] Cleaning Sophos identity..." -ForegroundColor Yellow

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
            Remove-Item "$persistPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "      Removed: MCS Persist folder" -ForegroundColor Gray
            $cleaned = $true
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
    Write-Host "[5/7] Skipping Sophos cleanup" -ForegroundColor Gray
}

# 6. Normalize Edge for Sysprep
Write-Host "[6/7] Normalizing Edge for Sysprep..." -ForegroundColor Yellow

Get-AppxPackage -AllUsers Microsoft.MicrosoftEdge.Stable |
    Where-Object { $_.PackageUserInformation.InstallState -eq "Installed" } |
    Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

$prov = Get-AppxProvisionedPackage -Online |
        Where-Object DisplayName -eq "Microsoft.MicrosoftEdge.Stable"

if ($prov) {
    Write-Host "      Re-registering provisioned Edge..." -ForegroundColor Gray
    Add-AppxProvisionedPackage `
        -Online `
        -PackagePath $prov.PackagePath `
        -SkipLicense `
        -ErrorAction SilentlyContinue
}

Get-AppxPackage -AllUsers Microsoft.WebView2Runtime |
    Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

Write-Host "      Done" -ForegroundColor Green

# 7. Sysprep
if (-not $SkipSysprep) {
    Write-Host "[7/7] Running sysprep..." -ForegroundColor Yellow
    Write-Host "      System will shutdown when complete..." -ForegroundColor Yellow
    Start-Process "$env:SystemRoot\System32\Sysprep\sysprep.exe" `
        -ArgumentList "/generalize /oobe /shutdown /mode:vm" `
        -Wait
} else {
    Write-Host "[7/7] Skipping sysprep" -ForegroundColor Gray
    Write-Host "`nCleanup complete. Run sysprep manually when ready." -ForegroundColor Green
}
