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
    [ValidatePattern('^wl[0-9]+$')]
    [string]$Radio = 'wl0',
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [string]$WiredWanInterface = 'vlan2',
    [string]$BackupDirectory = "$HOME\RouterBackups\DD-WRT",
    [ValidateRange(1, 65535)]
    [int]$TelnetPort = 23,
    [ValidateRange(1024, 65535)]
    [int]$TransferPort = 8081,
    [ValidateRange(30, 600)]
    [int]$WaitTimeoutSeconds = 180,
    [ValidateRange(0, 180)]
    [int]$PostBootDelaySeconds = 60,
    [SecureString]$TelnetPassword,
    [switch]$ClearMacClone,
    [ValidatePattern('^(?i:[0-9a-f]{2}:){5}[0-9a-f]{2}$')]
    [string]$PhysicalRadioMac,
    [ValidatePattern('^(?i:[0-9a-f]{2}:){5}[0-9a-f]{2}$')]
    [string]$PhysicalWiredWanMac
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
    # Windows PowerShell 5.1 can promote a native program's stderr to a
    # terminating NativeCommandError when the script preference is Stop.
    # Authentication failure is expected during first-time detection, so
    # contain it locally and decide only from OpenSSH's process exit code.
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $script:SshExe -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 `
            -i $KeyPath "$RouterUser@$RouterAddress" true 2>$null
        $sshExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    return ($sshExitCode -eq 0)
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

function Write-TelnetBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

function Write-TelnetLine {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    Write-TelnetBytes -Stream $Stream `
        -Bytes ([Text.Encoding]::ASCII.GetBytes("$Text`r`n"))
}

function Read-TelnetByte {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][datetime]$Deadline
    )
    while ((Get-Date) -lt $Deadline) {
        if ($Stream.DataAvailable) {
            return $Stream.ReadByte()
        }
        Start-Sleep -Milliseconds 20
    }
    throw 'Timed out inside a Telnet negotiation sequence.'
}

function Read-TelnetUntil {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )

    $iac = 255
    $will = 251
    $wont = 252
    $do = 253
    $dont = 254
    $sub = 250
    $subEnd = 240
    $echo = 1
    $suppressGoAhead = 3
    $windowSize = 31
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $text = [Text.StringBuilder]::new()

    while ((Get-Date) -lt $deadline) {
        if (-not $Stream.DataAvailable) {
            Start-Sleep -Milliseconds 20
            continue
        }

        $value = $Stream.ReadByte()
        if ($value -lt 0) {
            break
        }
        if ($value -ne $iac) {
            [void]$text.Append([char]$value)
            if ($text.ToString() -match $Pattern) {
                return $text.ToString()
            }
            continue
        }

        $command = Read-TelnetByte -Stream $Stream -Deadline $deadline
        if ($command -eq $iac) {
            [void]$text.Append([char]$iac)
            continue
        }
        if ($command -eq $sub) {
            $previous = -1
            do {
                $current = Read-TelnetByte -Stream $Stream -Deadline $deadline
                if ($previous -eq $iac -and $current -eq $subEnd) { break }
                $previous = $current
            } while ($true)
            continue
        }

        $option = Read-TelnetByte -Stream $Stream -Deadline $deadline
        switch ($command) {
            $will {
                $reply = if ($option -in @($echo, $suppressGoAhead)) { $do } else { $dont }
                Write-TelnetBytes -Stream $Stream -Bytes ([byte[]]@($iac, $reply, $option))
            }
            $wont {
                Write-TelnetBytes -Stream $Stream -Bytes ([byte[]]@($iac, $dont, $option))
            }
            $do {
                $accepted = $option -in @($echo, $suppressGoAhead, $windowSize)
                $reply = if ($accepted) { $will } else { $wont }
                Write-TelnetBytes -Stream $Stream -Bytes ([byte[]]@($iac, $reply, $option))
                if ($option -eq $windowSize) {
                    # IAC SB NAWS 80x24 IAC SE
                    Write-TelnetBytes -Stream $Stream `
                        -Bytes ([byte[]]@($iac, $sub, $windowSize, 0, 80, 0, 24, $iac, $subEnd))
                }
            }
            $dont {
                Write-TelnetBytes -Stream $Stream -Bytes ([byte[]]@($iac, $wont, $option))
            }
        }
    }

    $visible = $text.ToString().Replace("`r", '').Replace("`n", ' ')
    throw "Timed out waiting for Telnet pattern '$Pattern'. Output: $visible"
}

function Start-TelnetBootstrap {
    param([Parameter(Mandatory = $true)][SecureString]$Password)

    $publicKey = (Get-Content -Raw "$KeyPath.pub").Trim()
    $publicKeyArg = ConvertTo-ShellLiteral $publicKey
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = "before-ssh-bootstrap-$stamp.bin"

    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        if ($plainPassword.Contains("`r") -or $plainPassword.Contains("`n")) {
            throw 'The Telnet password cannot contain a newline.'
        }

        $client.Connect($RouterAddress, $TelnetPort)
        $stream = $client.GetStream()
        [void](Read-TelnetUntil -Stream $stream -Pattern 'DD-WRT login:')
        Write-TelnetLine -Stream $stream -Text $RouterUser
        [void](Read-TelnetUntil -Stream $stream -Pattern 'Password:')
        Write-TelnetLine -Stream $stream -Text $plainPassword
        $loginOutput = Read-TelnetUntil -Stream $stream -Pattern 'root@DD-WRT' `
            -TimeoutSeconds 20
        if ($loginOutput -match 'Login incorrect') {
            throw 'DD-WRT rejected the Telnet username or password.'
        }

        Write-Host 'Creating the pre-bootstrap NVRAM backup...'
        Write-TelnetLine -Stream $stream -Text (
            "nvram backup /tmp/$backupName; nc -l -p $TransferPort < /tmp/$backupName &"
        )
        [void](Read-TelnetUntil -Stream $stream -Pattern 'root@DD-WRT')

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
        Write-TelnetLine -Stream $stream -Text (
            "nvram set sshd_authorized_keys=$publicKeyArg; " +
            'nvram set sshd_enable=1; nvram set sshd_passwd_auth=1; ' +
            'nvram commit; stopservice sshd >/dev/null 2>&1 || true; ' +
            'startservice sshd'
        )
        [void](Read-TelnetUntil -Stream $stream -Pattern 'root@DD-WRT' `
            -TimeoutSeconds 30)
        Write-TelnetLine -Stream $stream -Text 'exit'
    }
    finally {
        $plainPassword = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
    }

    Write-Host 'SSH bootstrap committed; waiting for the service to accept the key...'
    $deadline = (Get-Date).AddSeconds(30)
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
if ($ClearMacClone) {
    $modeArguments.ClearMacClone = $true
    $modeArguments.PhysicalRadioMac = $PhysicalRadioMac
    $modeArguments.PhysicalWiredWanMac = $PhysicalWiredWanMac
}
if ($usedTelnetBootstrap) {
    # A fresh Telnet bootstrap already made the pre-change NVRAM backup. An
    # existing SSH installation still receives set-router-mode's normal backup.
    $modeArguments.NoBackup = $true
}

& $ModeScript @modeArguments
