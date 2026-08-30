[CmdletBinding()]
param(
    [string]$InterfaceAlias = "Ethernet",
    [string]$ResultPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InterfaceSnapshot {
    param([string]$Alias)

    $adapter = Get-NetAdapter -Name $Alias -ErrorAction Stop
    $ipv4Interface = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object IPAddress, PrefixLength, PrefixOrigin, SuffixOrigin, AddressState
    )
    $gateways = @(
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Select-Object NextHop, RouteMetric, State, Protocol
    )
    $dns = @(
        (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
    )

    return [ordered]@{
        InterfaceAlias = $adapter.Name
        InterfaceIndex = $adapter.ifIndex
        InterfaceGuid = [string]$adapter.InterfaceGuid
        Description = $adapter.InterfaceDescription
        Status = [string]$adapter.Status
        MediaConnectionState = [string]$adapter.MediaConnectionState
        LinkSpeed = [string]$adapter.LinkSpeed
        Dhcp = [string]$ipv4Interface.Dhcp
        Addresses = $addresses
        DefaultGateways = $gateways
        DnsServers = $dns
    }
}

function Write-Result {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 8
    if ($Path) {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    $json
}

$startedAt = [DateTimeOffset]::Now
$before = $null

try {
    if (-not (Test-Administrator)) {
        throw "This repair must run from an elevated PowerShell process."
    }

    $before = Get-InterfaceSnapshot -Alias $InterfaceAlias
    if ($before.Status -ne "Up" -or $before.MediaConnectionState -ne "Connected") {
        throw "The wired adapter is not physically connected."
    }

    # `netsh ... set address source=dhcp store=persistent` both enables DHCP
    # across reboots and removes stale static IPv4 addresses/default routes.
    & "$env:SystemRoot\System32\netsh.exe" interface ipv4 set address `
        name="$InterfaceAlias" source=dhcp store=persistent | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh could not enable persistent IPv4 DHCP."
    }

    & "$env:SystemRoot\System32\netsh.exe" interface ipv4 set dnsservers `
        name="$InterfaceAlias" source=dhcp register=primary validate=no | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "netsh could not restore automatic DNS."
    }

    # Switching the interface to DHCP starts address acquisition. Poll the
    # resulting state directly instead of invoking `ipconfig /renew`, whose
    # process-level timeout is not reliably bounded on Windows PowerShell 5.1.
    $deadline = (Get-Date).AddSeconds(45)
    $lease = $null
    $gateway = $null
    do {
        Start-Sleep -Seconds 1
        $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
        $lease = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AddressState -eq "Preferred" -and
                $_.PrefixOrigin -eq "Dhcp" -and
                $_.IPAddress -notlike "169.254.*"
            } |
            Select-Object -First 1
        $gateway = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq "Alive" -and $_.NextHop -ne "0.0.0.0" } |
            Select-Object -First 1
    } while ((-not $lease -or -not $gateway) -and (Get-Date) -lt $deadline)

    if (-not $lease -or -not $gateway) {
        throw "DHCP was enabled, but no usable IPv4 lease/default gateway arrived within 45 seconds."
    }

    $after = Get-InterfaceSnapshot -Alias $InterfaceAlias
    $selected = @(Find-NetRoute -RemoteIPAddress "1.1.1.1" -ErrorAction SilentlyContinue)
    $selectedRoute = $selected |
        Where-Object { $_.PSObject.Properties.Name -contains "DestinationPrefix" } |
        Select-Object -First 1
    $routeUsesEthernet = $false
    if ($selectedRoute) {
        $routeUsesEthernet = $selectedRoute.InterfaceIndex -eq $after.InterfaceIndex
    }

    & "$env:SystemRoot\System32\ping.exe" -n 2 -w 1500 -S $lease.IPAddress $gateway.NextHop | Out-Null
    $gatewayReachable = $LASTEXITCODE -eq 0
    & "$env:SystemRoot\System32\ping.exe" -n 2 -w 1500 -S $lease.IPAddress 1.1.1.1 | Out-Null
    $internetReachable = $LASTEXITCODE -eq 0

    $result = [ordered]@{
        SchemaVersion = 1
        Success = $true
        StartedAt = $startedAt.ToString("o")
        FinishedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        Before = $before
        After = $after
        PreferredInternetRouteUsesEthernet = $routeUsesEthernet
        GatewayReachableFromEthernet = $gatewayReachable
        InternetReachableFromEthernet = $internetReachable
    }
    Write-Result -Value $result -Path $ResultPath
}
catch {
    $failure = [ordered]@{
        SchemaVersion = 1
        Success = $false
        StartedAt = $startedAt.ToString("o")
        FinishedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        Before = $before
        Error = $_.Exception.Message
    }
    Write-Result -Value $failure -Path $ResultPath
    exit 1
}
