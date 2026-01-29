<#
.SYNOPSIS
    Post-deployment configuration for Windows Server 2025
.DESCRIPTION
    Configures computer name, network settings, verifies prerequisites, and generates deployment report
.EXAMPLE
    irm https://raw.githubusercontent.com/IT2Grow/ws2025-proxmox-template/main/Initialize-Server.ps1 | iex
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
$Script:Checks = @()

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Value,
        [string]$Fix
    )
    $Script:Checks += [PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Value  = $Value
        Fix    = $Fix
    }
}

Write-Host "`n=== Windows Server 2025 Post-Deployment ===" -ForegroundColor Cyan
Write-Host "IT2Grow B.V.`n" -ForegroundColor Cyan

#region Detect Existing Configuration
$currentName = $env:COMPUTERNAME
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
$currentIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
             Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
$currentGW = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop
$currentDNS = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses

# Check if hostname is non-default (not WIN-XXXXXX or TPL-xxx pattern)
$isDefaultHostname = $currentName -match '^(WIN-[A-Z0-9]{7,}|TPL-[A-Z0-9]+)$'

# Check if IP is static (not DHCP)
$isStaticIP = $currentIP -and $currentIP.PrefixOrigin -eq 'Manual'

$skipConfig = $false
$ComputerName = $currentName
$VlanId = $null
$DNSSuffix = "it2grow.nl"

if (-not $isDefaultHostname -or $isStaticIP) {
    Write-Host "Detected existing configuration:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Computer Name : $currentName" -ForegroundColor White
    if ($currentIP) {
        Write-Host "  IP Address    : $($currentIP.IPAddress)/$($currentIP.PrefixLength)" -ForegroundColor White
    }
    if ($currentGW) {
        Write-Host "  Gateway       : $currentGW" -ForegroundColor White
    }
    if ($currentDNS) {
        Write-Host "  DNS Servers   : $($currentDNS -join ', ')" -ForegroundColor White
    }
    Write-Host ""
    
    $confirm = Read-Host "Is this correct? (Y/n)"
    if ($confirm -eq '' -or $confirm -eq 'y' -or $confirm -eq 'Y') {
        $skipConfig = $true
        Write-Host "`nSkipping configuration, running checklist only...`n" -ForegroundColor Green
    } else {
        Write-Host "`nProceeding with reconfiguration...`n" -ForegroundColor Yellow
    }
}
#endregion

#region Gather Input (if needed)
if (-not $skipConfig) {
    $ComputerName = Read-Host "Enter computer name"
    if (-not $ComputerName) {
        Write-Host "Computer name is required." -ForegroundColor Red
        exit 1
    }

    $useStatic = Read-Host "Configure static IP? (y/N)"
    $IPAddress = $null
    $Gateway = $null
    $DNS = $null

    if ($useStatic -eq 'y') {
        $IPAddress = Read-Host "IP Address (e.g., 10.0.1.50)"
        $SubnetPrefix = Read-Host "Subnet prefix [24]"
        if (-not $SubnetPrefix) { $SubnetPrefix = "24" }
        $Gateway = Read-Host "Gateway (e.g., 10.0.1.1)"
        $dnsInput = Read-Host "DNS Servers, comma-separated (e.g., 10.0.1.10,10.0.1.11)"
        if ($dnsInput) { $DNS = $dnsInput -split ',' | ForEach-Object { $_.Trim() } }
        $VlanId = Read-Host "VLAN ID for Proxmox (leave empty if unchanged)"
    }
}
#endregion

#region Configuration (if needed)
if (-not $skipConfig) {
    # 1. Set computer name
    Write-Host "[1/4] Setting computer name to $ComputerName..." -ForegroundColor Yellow
    if ($ComputerName -ne $currentName) {
        Rename-Computer -NewName $ComputerName -Force -ErrorAction SilentlyContinue
    }
    Write-Host "      Done" -ForegroundColor Green

    # 2. Configure network
    Write-Host "[2/4] Configuring network..." -ForegroundColor Yellow

    if ($IPAddress) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | 
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        $ipParams = @{
            InterfaceIndex = $adapter.ifIndex
            IPAddress = $IPAddress
            PrefixLength = $SubnetPrefix
            AddressFamily = 'IPv4'
        }
        if ($Gateway) { $ipParams.DefaultGateway = $Gateway }
        
        New-NetIPAddress @ipParams | Out-Null
        Write-Host "      IP: $IPAddress/$SubnetPrefix" -ForegroundColor Gray
        if ($Gateway) { Write-Host "      Gateway: $Gateway" -ForegroundColor Gray }
    }

    if ($DNS) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DNS
        Write-Host "      DNS: $($DNS -join ', ')" -ForegroundColor Gray
    }

    Set-DnsClientGlobalSetting -SuffixSearchList @($DNSSuffix) -ErrorAction SilentlyContinue
    Set-DnsClient -InterfaceIndex $adapter.ifIndex -ConnectionSpecificSuffix $DNSSuffix -ErrorAction SilentlyContinue
    Write-Host "      DNS Suffix: $DNSSuffix" -ForegroundColor Gray
    Write-Host "      Done" -ForegroundColor Green

    # 3. Verify QEMU Guest Agent
    Write-Host "[3/4] Checking QEMU Guest Agent..." -ForegroundColor Yellow
    $qemu = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if ($qemu -and $qemu.Status -ne 'Running') {
        Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    }
    Write-Host "      Done" -ForegroundColor Green

    # 4. Azure Arc Onboarding
    Write-Host "[4/4] Azure Arc onboarding..." -ForegroundColor Yellow
    $arcScriptPath = "C:\ProgramData\AzureArc\connect.ps1"
    
    if (Test-Path $arcScriptPath) {
        $runArc = Read-Host "Run Azure Arc onboarding now? (Y/n)"
        if ($runArc -eq '' -or $runArc -eq 'y' -or $runArc -eq 'Y') {
            try {
                Write-Host "      Running Arc onboarding script..." -ForegroundColor Gray
                & $arcScriptPath
                Write-Host "      Arc onboarding completed" -ForegroundColor Green
            }
            catch {
                Write-Host "      Failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "      You can run it manually later: $arcScriptPath" -ForegroundColor Yellow
            }
        } else {
            Write-Host "      Skipped - Run manually: $arcScriptPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "      Arc script not found at $arcScriptPath" -ForegroundColor Yellow
        Write-Host "      Place connect.ps1 in C:\ProgramData\AzureArc\ and run manually" -ForegroundColor Gray
    }
    Write-Host "      Done" -ForegroundColor Green
    Write-Host ""
}
#endregion

#region Checklist
Write-Host "Running deployment checklist..." -ForegroundColor Yellow
Write-Host ""

# Refresh adapter info
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1

# Check: Computer Name
$currentName = $env:COMPUTERNAME
if ($currentName -eq $ComputerName) {
    Add-Check -Name "Computer Name" -Status "Pass" -Value $ComputerName -Fix ""
} else {
    Add-Check -Name "Computer Name" -Status "Warning" -Value "$currentName (pending: $ComputerName)" -Fix "Reboot required to apply new name"
}

# Check: IP Configuration
$ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
if ($ipConfig) {
    Add-Check -Name "IP Address" -Status "Pass" -Value "$($ipConfig.IPAddress)/$($ipConfig.PrefixLength)" -Fix ""
} else {
    Add-Check -Name "IP Address" -Status "Fail" -Value "Not configured" -Fix "Set static IP or verify DHCP"
}

# Check: Default Gateway
$gw = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
if ($gw) {
    Add-Check -Name "Default Gateway" -Status "Pass" -Value $gw.NextHop -Fix ""
} else {
    Add-Check -Name "Default Gateway" -Status "Fail" -Value "Not configured" -Fix "Configure default gateway"
}

# Check: DNS Servers
$dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
if ($dnsServers) {
    Add-Check -Name "DNS Servers" -Status "Pass" -Value ($dnsServers -join ", ") -Fix ""
} else {
    Add-Check -Name "DNS Servers" -Status "Fail" -Value "Not configured" -Fix "Configure DNS servers"
}

# Check: DNS Suffix
$suffix = (Get-DnsClient -InterfaceIndex $adapter.ifIndex).ConnectionSpecificSuffix
if ($suffix -eq $DNSSuffix) {
    Add-Check -Name "DNS Suffix" -Status "Pass" -Value $suffix -Fix ""
} else {
    Add-Check -Name "DNS Suffix" -Status "Warning" -Value ($suffix ? $suffix : "Not set") -Fix "Set DNS suffix to $DNSSuffix"
}

# Check: Internet Connectivity
$internet = Test-NetConnection -ComputerName "8.8.8.8" -Port 443 -WarningAction SilentlyContinue
if ($internet.TcpTestSucceeded) {
    Add-Check -Name "Internet Access" -Status "Pass" -Value "Connected" -Fix ""
} else {
    Add-Check -Name "Internet Access" -Status "Fail" -Value "No connection" -Fix "Check network/firewall settings"
}

# Check: QEMU Guest Agent
$qemu = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($qemu -and $qemu.Status -eq 'Running') {
    Add-Check -Name "QEMU Guest Agent" -Status "Pass" -Value "Running" -Fix ""
} elseif ($qemu) {
    Add-Check -Name "QEMU Guest Agent" -Status "Warning" -Value $qemu.Status -Fix "Start-Service QEMU-GA"
} else {
    Add-Check -Name "QEMU Guest Agent" -Status "Fail" -Value "Not installed" -Fix "Install from virtio-win ISO"
}

# Check: Built-in Administrator disabled
$builtinAdmin = Get-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
if ($builtinAdmin) {
    if (-not $builtinAdmin.Enabled) {
        Add-Check -Name "Built-in Administrator" -Status "Pass" -Value "Disabled" -Fix ""
    } else {
        Add-Check -Name "Built-in Administrator" -Status "Fail" -Value "Enabled" -Fix "Disable-LocalUser -Name 'Administrator'"
    }
}

# Check: it2gadmin account
$it2gAdmin = Get-LocalUser -Name "it2gadmin" -ErrorAction SilentlyContinue
$it2gAdminInGroup = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\it2gadmin" }

if ($it2gAdmin -and $it2gAdminInGroup) {
    if ($it2gAdmin.Enabled) {
        Add-Check -Name "it2gadmin Account" -Status "Pass" -Value "Exists, enabled, administrator" -Fix ""
    } else {
        Add-Check -Name "it2gadmin Account" -Status "Warning" -Value "Exists but disabled" -Fix "Enable-LocalUser -Name 'it2gadmin'"
    }
} elseif ($it2gAdmin) {
    Add-Check -Name "it2gadmin Account" -Status "Warning" -Value "Exists but not in Administrators group" -Fix "Add-LocalGroupMember -Group 'Administrators' -Member 'it2gadmin'"
} else {
    Add-Check -Name "it2gadmin Account" -Status "Fail" -Value "Not found" -Fix "Create it2gadmin account and add to Administrators"
}

# Check: Azure Arc
$arcService = Get-Service -Name "himds" -ErrorAction SilentlyContinue
$arcAgent = Test-Path "${env:ProgramFiles}\AzureConnectedMachineAgent\azcmagent.exe"
if ($arcService -and $arcService.Status -eq 'Running') {
    Add-Check -Name "Azure Arc" -Status "Pass" -Value "Connected" -Fix ""
} elseif ($arcAgent) {
    Add-Check -Name "Azure Arc" -Status "Warning" -Value "Installed, not connected" -Fix "Run C:\ProgramData\AzureArc\connect.ps1"
} else {
    Add-Check -Name "Azure Arc" -Status "Fail" -Value "Not installed" -Fix "Run Arc onboarding script from Azure Portal"
}

# Check: Sophos Endpoint
$sophosServices = Get-Service -Name "Sophos*" -ErrorAction SilentlyContinue
$sophosInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | 
                   Where-Object { $_.DisplayName -like "*Sophos*" }
$sophosMCS = Get-Service -Name "Sophos MCS Client" -ErrorAction SilentlyContinue

$sophosConnected = $false
if ($sophosMCS -and $sophosMCS.Status -eq 'Running') {
    $mcsStatus = Get-ItemProperty "HKLM:\SOFTWARE\Sophos\Management Communications System\Endpoint" -ErrorAction SilentlyContinue
    if ($mcsStatus -and $mcsStatus.Id) {
        $sophosConnected = $true
    }
}

if ($sophosConnected) {
    Add-Check -Name "Sophos Endpoint" -Status "Pass" -Value "Running, connected to Central" -Fix ""
} elseif ($sophosServices | Where-Object { $_.Status -eq 'Running' }) {
    Add-Check -Name "Sophos Endpoint" -Status "Warning" -Value "Running, not connected to Central" -Fix "Check Sophos Central connection"
} elseif ($sophosInstalled) {
    Add-Check -Name "Sophos Endpoint" -Status "Warning" -Value "Installed, not running" -Fix "Check Sophos services"
} else {
    Add-Check -Name "Sophos Endpoint" -Status "Fail" -Value "Not installed" -Fix "Install from Sophos Central"
}

# Check: Windows Firewall
$fwProfiles = Get-NetFirewallProfile
$fwEnabled = $fwProfiles | Where-Object { $_.Enabled -eq $true }
if ($fwEnabled.Count -eq 3) {
    Add-Check -Name "Windows Firewall" -Status "Pass" -Value "All profiles enabled" -Fix ""
} else {
    Add-Check -Name "Windows Firewall" -Status "Warning" -Value "$($fwEnabled.Count)/3 profiles enabled" -Fix "Enable all firewall profiles"
}

# Check: RDP
$rdp = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
if ($rdp -eq 0) {
    Add-Check -Name "Remote Desktop" -Status "Pass" -Value "Enabled" -Fix ""
} else {
    Add-Check -Name "Remote Desktop" -Status "Warning" -Value "Disabled" -Fix "Enable Remote Desktop in System Settings"
}

# Check: Proxmox VLAN (reminder)
if ($VlanId) {
    Add-Check -Name "Proxmox VLAN" -Status "Warning" -Value "VLAN $VlanId" -Fix "Set VLAN tag $VlanId in Proxmox: VM > Hardware > Network > VLAN Tag"
}
#endregion

#region Display Results
Write-Host "=== Deployment Checklist Results ===" -ForegroundColor Cyan
Write-Host ""

$failed = @()
$warnings = @()

foreach ($check in $Script:Checks) {
    switch ($check.Status) {
        "Pass" {
            Write-Host "  [OK]   " -ForegroundColor Green -NoNewline
            Write-Host "$($check.Name): " -NoNewline
            Write-Host $check.Value -ForegroundColor Gray
        }
        "Warning" {
            Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline
            Write-Host "$($check.Name): " -NoNewline
            Write-Host $check.Value -ForegroundColor Gray
            $warnings += $check
        }
        "Fail" {
            Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline
            Write-Host "$($check.Name): " -NoNewline
            Write-Host $check.Value -ForegroundColor Gray
            $failed += $check
        }
    }
}

Write-Host ""

# Show fixes needed
if ($failed.Count -gt 0 -or $warnings.Count -gt 0) {
    Write-Host "=== Actions Required ===" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($check in ($failed + $warnings)) {
        if ($check.Fix) {
            Write-Host "  - $($check.Name): " -NoNewline
            Write-Host $check.Fix -ForegroundColor Cyan
        }
    }
    
    Write-Host ""
    Write-Host "Found $($failed.Count) failed and $($warnings.Count) warnings." -ForegroundColor Yellow
    Write-Host ""
    
    $continue = Read-Host "Generate report anyway? (y/N)"
    if ($continue -ne 'y') {
        Write-Host "Fix issues and run again." -ForegroundColor Yellow
        exit 1
    }
}
#endregion

#region Generate HTML Report
$reportPath = "$env:USERPROFILE\Desktop\$ComputerName-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$vlanNote = ""
if ($VlanId) {
    $vlanNote = "<p style='background: #fff4ce; padding: 10px; border-radius: 4px;'><strong>⚠ Proxmox Action Required:</strong> Set VLAN tag <strong>$VlanId</strong> in Proxmox: VM &gt; Hardware &gt; Network Device &gt; VLAN Tag</p>"
}

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Deployment Report - $ComputerName</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #666; margin-top: 30px; }
        .meta { color: #666; margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f8f8; font-weight: 600; }
        .pass { color: #107c10; }
        .warning { color: #ca5010; }
        .fail { color: #d13438; }
        .status-icon { font-weight: bold; margin-right: 5px; }
        .fix { font-size: 12px; color: #666; font-style: italic; }
        .summary { display: flex; gap: 20px; margin: 20px 0; }
        .summary-box { padding: 15px 25px; border-radius: 4px; text-align: center; }
        .summary-pass { background: #dff6dd; color: #107c10; }
        .summary-warn { background: #fff4ce; color: #ca5010; }
        .summary-fail { background: #fde7e9; color: #d13438; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Deployment Report</h1>
        <div class="meta">
            <strong>Server:</strong> $ComputerName<br>
            <strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
            <strong>Generated by:</strong> $env:USERNAME
        </div>
        
        $vlanNote
        
        <div class="summary">
            <div class="summary-box summary-pass">
                <div style="font-size: 24px; font-weight: bold;">$(($Script:Checks | Where-Object { $_.Status -eq 'Pass' }).Count)</div>
                <div>Passed</div>
            </div>
            <div class="summary-box summary-warn">
                <div style="font-size: 24px; font-weight: bold;">$(($Script:Checks | Where-Object { $_.Status -eq 'Warning' }).Count)</div>
                <div>Warnings</div>
            </div>
            <div class="summary-box summary-fail">
                <div style="font-size: 24px; font-weight: bold;">$(($Script:Checks | Where-Object { $_.Status -eq 'Fail' }).Count)</div>
                <div>Failed</div>
            </div>
        </div>
        
        <h2>Checklist Results</h2>
        <table>
            <tr>
                <th>Check</th>
                <th>Status</th>
                <th>Value</th>
            </tr>
"@

foreach ($check in $Script:Checks) {
    $statusClass = $check.Status.ToLower()
    $statusIcon = switch ($check.Status) {
        "Pass" { "&#10003;" }
        "Warning" { "&#9888;" }
        "Fail" { "&#10007;" }
    }
    
    $fixHtml = if ($check.Fix) { "<br><span class='fix'>Fix: $($check.Fix)</span>" } else { "" }
    
    $html += @"
            <tr>
                <td>$($check.Name)</td>
                <td class="$statusClass"><span class="status-icon">$statusIcon</span>$($check.Status)</td>
                <td>$($check.Value)$fixHtml</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <h2>Next Steps</h2>
        <ol>
            <li>Complete any failed/warning items above</li>
            <li>Run Azure Arc onboarding script (if not already completed)</li>
            <li>Install Sophos Endpoint from Sophos Central</li>
            <li>Reboot to apply computer name (if changed)</li>
        </ol>
        
        <div class="footer">
            IT2Grow B.V. - Windows Server 2025 Deployment
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "Report saved to: $reportPath" -ForegroundColor Green
#endregion

# Open report
Start-Process $reportPath

Write-Host ""
$reboot = Read-Host "Reboot now? (y/N)"
if ($reboot -eq 'y') {
    Restart-Computer -Force
}
