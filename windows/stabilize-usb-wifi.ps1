[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Status', 'Restore')]
    [string]$Action = 'Status',
    [string]$InterfaceAlias = 'Wi-Fi',
    [string]$ProfileName = '',
    [string]$PreferredBssid = '',
    [string]$BackupPath = "$env:ProgramData\WIFI2LAN\usb-wifi-backup.json"
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell.'
    }
}

function Get-State {
    $adapter = Get-NetAdapter -Name $InterfaceAlias
    $radio = Get-NetAdapterAdvancedProperty -Name $InterfaceAlias `
        -DisplayName '802.11 Wireless Mode'
    $ip = Get-NetIPInterface -InterfaceAlias $InterfaceAlias `
        -AddressFamily IPv4
    [pscustomobject]@{
        InterfaceAlias = $InterfaceAlias
        AdapterStatus = $adapter.Status
        Driver = $adapter.DriverInformation
        WirelessMode = $radio.DisplayValue
        AutomaticMetric = $ip.AutomaticMetric
        InterfaceMetric = $ip.InterfaceMetric
    }
}

if ($Action -eq 'Status') {
    Get-State | Format-List
    netsh.exe wlan show interfaces
    exit $LASTEXITCODE
}

Assert-Administrator

if ($Action -eq 'Restore') {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup not found: $BackupPath"
    }
    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    Set-NetAdapterAdvancedProperty -Name $InterfaceAlias `
        -DisplayName '802.11 Wireless Mode' `
        -DisplayValue $backup.WirelessMode -NoRestart
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 `
        -AutomaticMetric $backup.AutomaticMetric `
        -InterfaceMetric $backup.InterfaceMetric
} else {
    $state = Get-State
    $directory = Split-Path -Parent $BackupPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        $state | ConvertTo-Json | Set-Content -LiteralPath $BackupPath `
            -Encoding utf8
    }
    Set-NetAdapterAdvancedProperty -Name $InterfaceAlias `
        -DisplayName '802.11 Wireless Mode' `
        -DisplayValue '2.4GHz 802.11b/g/n' -NoRestart
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 `
        -AutomaticMetric Disabled -InterfaceMetric 25
}

Disable-NetAdapter -Name $InterfaceAlias -Confirm:$false
Start-Sleep -Seconds 2
Enable-NetAdapter -Name $InterfaceAlias -Confirm:$false
Start-Sleep -Seconds 4

if ($Action -eq 'Apply' -and $ProfileName) {
    $arguments = @(
        'wlan', 'connect', "name=$ProfileName", "ssid=$ProfileName",
        "interface=$InterfaceAlias"
    )
    if ($PreferredBssid) {
        $arguments += "bssid=$PreferredBssid"
    }
    & netsh.exe @arguments
}

Get-State | Format-List
