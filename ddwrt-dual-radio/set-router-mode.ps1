[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('wifi', 'wired', 'status')]
    [string]$Mode,

    [string]$UpstreamSsid,
    [string]$RouterAddress = '192.168.1.1',
    [string]$RouterUser = 'root',
    [string]$KeyPath = "$HOME\.ssh\astrill_lazy_router_ed25519",
    [string]$Radio = 'wl0',
    [string]$WiredWanInterface = 'vlan2',
    [string]$BackupDirectory = "$HOME\RouterBackups\DD-WRT",
    [switch]$NoBackup,
    [switch]$NoReboot
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
    & $script:SshExe -o BatchMode=yes -o ConnectTimeout=8 -i $KeyPath `
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
    & $ScpExe -O -q -i $KeyPath `
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

& $ScpExe -O -q -i $KeyPath $RouterScript `
    "${RouterUser}@${RouterAddress}:/tmp/configure-fixed-wifi-wan.sh"
if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the router script (scp exit $LASTEXITCODE)."
}

$radioArg = ConvertTo-ShellLiteral $Radio
$wiredArg = ConvertTo-ShellLiteral $WiredWanInterface
switch ($Mode) {
    'wifi' {
        $ssidArg = ConvertTo-ShellLiteral $UpstreamSsid
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
    & $SshExe -o BatchMode=yes -o ConnectTimeout=8 -i $KeyPath `
        "$RouterUser@$RouterAddress" reboot | Out-Null
    Write-Host 'The router normally takes about 60-120 seconds to return.'
}
