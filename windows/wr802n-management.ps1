[CmdletBinding()]
param(
    [ValidateSet("Enable", "RestoreDhcp")]
    [string]$Mode = "Enable",
    [string]$InterfaceAlias = "Ethernet 2",
    [ValidatePattern('^$|^(?i:[0-9a-f]{2}-){5}[0-9a-f]{2}$')]
    [string]$ExpectedMacAddress = "",
    [string]$LocalAddress = "192.168.1.252",
    [string]$RouterAddress = "192.168.1.253",
    [string]$TftpAddress = "192.168.0.66"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw "Run this script from an elevated PowerShell process."
}

$adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
if ($ExpectedMacAddress -and $adapter.MacAddress -ne $ExpectedMacAddress) {
    throw "Refusing to modify $InterfaceAlias because its MAC address changed."
}
if ($adapter.Status -ne "Up") {
    throw "$InterfaceAlias is not physically connected."
}

$existingRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex `
    -DestinationPrefix "$RouterAddress/32" -ErrorAction SilentlyContinue
$existingAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex `
    -AddressFamily IPv4 -IPAddress $LocalAddress -ErrorAction SilentlyContinue

if ($Mode -eq "Enable") {
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -IPAddress $TftpAddress -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false
    Get-NetFirewallRule -DisplayName `
        "WIFI2LAN WR802N TFTP UDP 69", `
        "WIFI2LAN WR802N TFTP UDP 1069" `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    & pktmon filter remove 2>$null | Out-Null

    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -Dhcp Disabled

    if (-not $existingAddress) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
            -IPAddress $LocalAddress -PrefixLength 32 -SkipAsSource $false | Out-Null
    }
    if (-not $existingRoute) {
        New-NetRoute -InterfaceIndex $adapter.ifIndex `
            -DestinationPrefix "$RouterAddress/32" -NextHop "0.0.0.0" `
            -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
    }
}
else {
    if ($existingRoute) {
        $existingRoute | Remove-NetRoute -Confirm:$false
    }
    if ($existingAddress) {
        $existingAddress | Remove-NetIPAddress -Confirm:$false
    }
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
        -ResetServerAddresses
}

[pscustomobject]@{
    Mode = $Mode
    InterfaceAlias = $adapter.Name
    InterfaceIndex = $adapter.ifIndex
    MacAddress = $adapter.MacAddress
    LocalAddress = $LocalAddress
    RouterAddress = $RouterAddress
}
