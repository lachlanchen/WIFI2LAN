[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('wifi', 'wired')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [string]$RouterAddress,

    [string]$UpstreamSsid,
    [string]$RouterUser = 'root',
    [string]$KeyPath = "$HOME\.ssh\astrill_lazy_router_ed25519",
    [string]$Radio = 'wl0',
    [string]$WiredWanInterface = 'vlan2',
    [string]$BackupDirectory = "$HOME\RouterBackups\DD-WRT",
    [string]$PlinkPath = 'C:\Program Files\PuTTY\plink.exe',
    [ValidateRange(1, 65535)]
    [int]$TelnetPort = 23,
    [ValidateRange(1024, 65535)]
    [int]$TransferPort = 8081,
    [ValidateRange(30, 600)]
    [int]$WaitTimeoutSeconds = 180,
    [ValidateRange(0, 180)]
    [int]$PostBootDelaySeconds = 60,
    [SecureString]$TelnetPassword
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

function Test-KeySsh {
    & $script:SshExe -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=5 `
        -i $KeyPath "$RouterUser@$RouterAddress" true 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Wait-RouterCycle {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
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
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Router did not complete a down/up cycle within $TimeoutSeconds seconds."
}

function Receive-RawFile {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $client = $null
    $stream = $null
    $memory = $null
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $client.Connect($Address, $Port)
            break
        }
        catch {
            $client.Dispose()
            $client = $null
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $client -or -not $client.Connected) {
        throw "Could not connect to the temporary router backup port $Port. Check the Telnet password."
    }

    try {
        $client.ReceiveTimeout = 10000
        $stream = $client.GetStream()
        $memory = [IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        return $memory.ToArray()
    }
    finally {
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
    }
}

function Start-TelnetBootstrap {
    param([Parameter(Mandatory = $true)][SecureString]$Password)

    $publicKey = (Get-Content -Raw "$KeyPath.pub").Trim()
    $publicKeyArg = ConvertTo-ShellLiteral $publicKey
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = "before-ssh-bootstrap-$stamp.bin"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PlinkPath
    $startInfo.Arguments = "-batch -telnet -P $TelnetPort $RouterAddress"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Could not start the Telnet client.'
    }

    $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        if ($plainPassword.Contains("`r") -or $plainPassword.Contains("`n")) {
            throw 'The Telnet password cannot contain a newline.'
        }

        # Old DD-WRT Telnet prompts are not newline-terminated. Pace stdin so
        # credentials cannot arrive before the login and password prompts.
        Start-Sleep -Milliseconds 1500
        $process.StandardInput.WriteLine($RouterUser)
        $process.StandardInput.Flush()
        Start-Sleep -Milliseconds 500
        $process.StandardInput.WriteLine($plainPassword)
        $process.StandardInput.Flush()
        Start-Sleep -Milliseconds 1000

        Write-Host 'Creating the pre-bootstrap NVRAM backup...'
        $process.StandardInput.WriteLine(
            "nvram backup /tmp/$backupName; nc -l -p $TransferPort < /tmp/$backupName &"
        )
        $process.StandardInput.Flush()
        Start-Sleep -Milliseconds 750

        $backupBytes = Receive-RawFile -Address $RouterAddress -Port $TransferPort
        $headerLength = [Math]::Min(8, $backupBytes.Length)
        $header = [Text.Encoding]::ASCII.GetString($backupBytes, 0, $headerLength)
        if ($backupBytes.Length -lt 1024 -or -not $header.StartsWith('DD-WRT')) {
            throw "Router backup validation failed (length=$($backupBytes.Length), header=$header)."
        }

        New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
        $backupPath = Join-Path $BackupDirectory $backupName
        [IO.File]::WriteAllBytes($backupPath, $backupBytes)
        $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash
        Write-Host "Backup: $backupPath"
        Write-Host "SHA256: $backupHash"

        Write-Host 'Installing the SSH management public key...'
        $process.StandardInput.WriteLine(
            "nvram set sshd_authorized_keys=$publicKeyArg; " +
            'nvram set sshd_enable=1; nvram set sshd_passwd_auth=1; ' +
            'nvram commit; reboot'
        )
        $process.StandardInput.Flush()

        if (-not $process.WaitForExit(20000)) {
            throw 'The Telnet session did not close for reboot; check the password and router console.'
        }
    }
    finally {
        $plainPassword = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        if (-not $process.HasExited) {
            $process.Kill()
        }
        $process.Dispose()
    }

    Write-Host 'SSH bootstrap committed; waiting for the router to reboot...'
    Wait-RouterCycle -TimeoutSeconds $WaitTimeoutSeconds

    $deadline = (Get-Date).AddSeconds(60)
    do {
        if (Test-KeySsh) {
            Write-Host 'SSH key login verified.'
            return
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw 'Router returned, but SSH key login did not become ready.'
}

$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$ModeScript = Join-Path $PSScriptRoot 'set-router-mode.ps1'

foreach ($path in @($SshExe, $KeyPath, "$KeyPath.pub", $ModeScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

if ($Mode -eq 'wifi' -and [string]::IsNullOrWhiteSpace($UpstreamSsid)) {
    throw 'UpstreamSsid is required for the first Wi-Fi-mode setup.'
}

$usedTelnetBootstrap = $false
if (-not (Test-KeySsh)) {
    if (-not (Test-Path -LiteralPath $PlinkPath)) {
        throw "SSH is unavailable and PuTTY Plink was not found: $PlinkPath"
    }
    if ($null -eq $TelnetPassword) {
        $TelnetPassword = Read-Host `
            "Telnet password for $RouterUser@$RouterAddress" -AsSecureString
    }
    Start-TelnetBootstrap -Password $TelnetPassword
    $usedTelnetBootstrap = $true
}
else {
    Write-Host 'SSH key login already works; skipping the Telnet bootstrap.'
}

$modeArguments = @{
    Mode = $Mode
    RouterAddress = $RouterAddress
    RouterUser = $RouterUser
    KeyPath = $KeyPath
    Radio = $Radio
    WiredWanInterface = $WiredWanInterface
    BackupDirectory = $BackupDirectory
    WaitTimeoutSeconds = $WaitTimeoutSeconds
    PostBootDelaySeconds = $PostBootDelaySeconds
}
if ($Mode -eq 'wifi') {
    $modeArguments.UpstreamSsid = $UpstreamSsid
}
if ($usedTelnetBootstrap) {
    # A fresh Telnet bootstrap already made the pre-change NVRAM backup. An
    # existing SSH installation still receives set-router-mode's normal backup.
    $modeArguments.NoBackup = $true
}

& $ModeScript @modeArguments
