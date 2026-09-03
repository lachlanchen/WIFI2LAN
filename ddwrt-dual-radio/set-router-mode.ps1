[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('wifi', 'wired', 'status')]
    [string]$Mode,

    [string]$UpstreamSsid,
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [string]$RouterAddress = '192.168.1.1',
    [string]$RouterUser = 'root',
    [string]$KeyPath = "$HOME\.ssh\astrill_lazy_router_ed25519",
    [string]$Radio = 'wl0',
    [string]$WiredWanInterface = 'vlan2',
    [string]$BackupDirectory = "$HOME\RouterBackups\DD-WRT",
    [ValidateRange(30, 600)]
    [int]$WaitTimeoutSeconds = 180,
    [ValidateRange(0, 180)]
    [int]$PostBootDelaySeconds = 60,
    [switch]$NoBackup,
    [switch]$NoReboot,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Contains("`r") -or $Value.Contains("`n") -or
        $Value.Contains([char]0) -or $Value.Contains("'")) {
        throw "Remote arguments cannot contain an apostrophe, newline, or NUL."
    }
    return "'$Value'"
}

function Invoke-Ssh {
    param([Parameter(Mandatory = $true)][string]$Command)
    & $script:SshExe -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=8 -i $KeyPath `
        "$RouterUser@$RouterAddress" $Command
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed with exit code $LASTEXITCODE."
    }
}

$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$ScpExe = "$env:WINDIR\System32\OpenSSH\scp.exe"
$RouterScript = Join-Path $PSScriptRoot 'configure-fixed-wifi-wan.sh'

foreach ($path in @($SshExe, $ScpExe, $KeyPath, $RouterScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

if ($Mode -ne 'status' -and -not $NoBackup) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $remoteBackup = "/tmp/before-router-mode-$stamp.bin"
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    Invoke-Ssh "nvram backup $remoteBackup"
    & $ScpExe -O -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=8 -i $KeyPath `
        "${RouterUser}@${RouterAddress}:$remoteBackup" $BackupDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy the NVRAM backup (scp exit $LASTEXITCODE)."
    }
    Invoke-Ssh "rm -f $remoteBackup"
    $localBackup = Join-Path $BackupDirectory (Split-Path $remoteBackup -Leaf)
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localBackup).Hash
    Write-Host "Backup: $localBackup"
    Write-Host "SHA256: $hash"
}

& $ScpExe -O -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
    -o ConnectTimeout=8 -i $KeyPath $RouterScript `
    "${RouterUser}@${RouterAddress}:/tmp/configure-fixed-wifi-wan.sh"
if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the router script (scp exit $LASTEXITCODE)."
}

$radioArg = ConvertTo-ShellLiteral $Radio
$wiredArg = ConvertTo-ShellLiteral $WiredWanInterface
switch ($Mode) {
    'wifi' {
        $ssidArg = ConvertTo-ShellLiteral ([string]$UpstreamSsid)
        Invoke-Ssh "sh /tmp/configure-fixed-wifi-wan.sh wifi $ssidArg $radioArg $wiredArg"
    }
    'wired' {
        Invoke-Ssh "sh /tmp/configure-fixed-wifi-wan.sh wired $radioArg $wiredArg"
    }
    'status' {
        Invoke-Ssh "sh /tmp/configure-fixed-wifi-wan.sh status $radioArg $wiredArg"
    }
}

if ($Mode -ne 'status' -and -not $NoReboot) {
    Write-Host "Rebooting $RouterAddress..."
    & $SshExe -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=8 -i $KeyPath `
        "$RouterUser@$RouterAddress" reboot | Out-Null
    Write-Host 'The router normally takes about 60-120 seconds to return.'

    if (-not $NoWait) {
        $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
        $sawOffline = $false
        $online = $false
        do {
            Start-Sleep -Seconds 2
            $online = Test-Connection -ComputerName $RouterAddress -Count 1 `
                -Quiet -ErrorAction SilentlyContinue
            if (-not $online) {
                $sawOffline = $true
            }
            if ($sawOffline -and $online) {
                break
            }
        } while ((Get-Date) -lt $deadline)

        if (-not ($sawOffline -and $online)) {
            throw "Router did not complete a down/up cycle within $WaitTimeoutSeconds seconds."
        }

        Write-Host "Router is reachable; allowing $PostBootDelaySeconds seconds for Wi-Fi DHCP and firewall startup..."
        Start-Sleep -Seconds $PostBootDelaySeconds

        & $ScpExe -O -q -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 `
            -i $KeyPath $RouterScript `
            "${RouterUser}@${RouterAddress}:/tmp/configure-fixed-wifi-wan.sh"
        if ($LASTEXITCODE -ne 0) {
            throw "Router returned, but the validation script upload failed (scp exit $LASTEXITCODE)."
        }
        Invoke-Ssh "sh /tmp/configure-fixed-wifi-wan.sh status $radioArg $wiredArg"
    }
}
