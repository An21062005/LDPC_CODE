param(
    [string]$ComPort = 'COM4'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localScript = Join-Path $scriptDir 'run_ldpc_full.py'
$remoteRoot = '/home/xilinx/pynq_z2_shared_work'
$remoteScript = "$remoteRoot/run_ldpc_full_698_v3.py"
$expectedSha256 = '43fa859064ecec7094afa03ac09efaebf51067b138cfe5588d390517edda5b13'

if ($remoteRoot -match '(?i)(^|/)loc(/|$)') {
    throw "Refusing protected destination: $remoteRoot"
}
if (-not (Test-Path -LiteralPath $localScript -PathType Leaf)) {
    throw "Missing local full-run script: $localScript"
}

function Read-SerialText {
    param(
        [IO.Ports.SerialPort]$Port,
        [int]$Seconds,
        [string]$Until = ''
    )
    $text = ''
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $text += $Port.ReadExisting()
        if ($Until -and $text -match $Until) { break }
    }
    return $text
}

function Read-BoardPassword {
    $secure = Read-Host 'Board password (characters stay hidden)' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# Compress first so the serial transfer is short, then Base64-wrap it so the
# Linux terminal never receives a line near its canonical input length limit.
$rawBytes = [IO.File]::ReadAllBytes($localScript)
$compressedStream = [IO.MemoryStream]::new()
$gzip = [IO.Compression.GZipStream]::new(
    $compressedStream,
    [IO.Compression.CompressionMode]::Compress,
    $true
)
$gzip.Write($rawBytes, 0, $rawBytes.Length)
$gzip.Dispose()
$payload = [Convert]::ToBase64String($compressedStream.ToArray())
$compressedStream.Dispose()

$wrapped = [Text.StringBuilder]::new($payload.Length + 256)
for ($offset = 0; $offset -lt $payload.Length; $offset += 76) {
    $count = [Math]::Min(76, $payload.Length - $offset)
    [void]$wrapped.Append($payload, $offset, $count)
    [void]$wrapped.Append("`r`n")
}
$transferText = $wrapped.ToString()

$port = [IO.Ports.SerialPort]::new(
    $ComPort,
    115200,
    [IO.Ports.Parity]::None,
    8,
    [IO.Ports.StopBits]::One
)
$port.Handshake = [IO.Ports.Handshake]::None
$port.ReadTimeout = 2000
$port.WriteTimeout = 120000
$port.DtrEnable = $false
$port.RtsEnable = $false

try {
    $port.Open()
    $port.DiscardInBuffer()
    $port.Write("`r")
    $screen = Read-SerialText -Port $port -Seconds 3

    # Closing MobaXterm can return the serial console to a login prompt. Handle
    # that here so the user does not need to paste transfer data manually.
    if ($screen -match '(?i)login:\s*$') {
        $port.Write("xilinx`r")
        $screen = Read-SerialText -Port $port -Seconds 5 -Until '(?i)password:'
    }
    if ($screen -match '(?i)password:\s*$') {
        $password = Read-BoardPassword
        try {
            $port.Write("$password`r")
        }
        finally {
            $password = $null
        }
        $screen = Read-SerialText -Port $port -Seconds 8
    }

    if ($screen -notmatch '(?m)[#$]\s*$') {
        $port.Write("`r")
        $screen += Read-SerialText -Port $port -Seconds 5
    }
    if ($screen -notmatch '(?m)[#$]\s*$') {
        throw "Board shell is not ready. Reopen COM4 in MobaXterm, log in until the xilinx@pynq prompt appears, then close that COM4 tab and rerun this command."
    }

    # Turn off shell echo only after a real shell prompt was confirmed. This
    # prevents echoed commands from being mistaken for board responses.
    $port.Write("stty -echo`r")
    Start-Sleep -Milliseconds 250
    $port.DiscardInBuffer()
    $port.Write("if test -e $remoteScript; then printf '__REMOTE_%s__\n' EXISTS; sha256sum $remoteScript; else printf '__REMOTE_%s__\n' READY; fi`r")
    $probe = Read-SerialText -Port $port -Seconds 8 -Until '__REMOTE_(READY|EXISTS)__'

    if ($probe -match '__REMOTE_EXISTS__') {
        $probe += Read-SerialText -Port $port -Seconds 2
        if ($probe -match $expectedSha256) {
            $port.Write("stty echo`r")
            Write-Output "SCRIPT_OK: verified existing $remoteScript"
            return
        }
        throw "Refusing to overwrite existing board file: $remoteScript"
    }
    if ($probe -notmatch '__REMOTE_READY__') {
        throw "Board shell did not answer the safe destination check"
    }

    $port.Write("base64 -d | gzip -d > $remoteScript`r")
    Start-Sleep -Milliseconds 200
    for ($offset = 0; $offset -lt $transferText.Length; $offset += 256) {
        $count = [Math]::Min(256, $transferText.Length - $offset)
        $port.Write($transferText.Substring($offset, $count))
        Start-Sleep -Milliseconds 10
    }
    $port.Write([char]4)

    $deadline = (Get-Date).AddSeconds(30)
    while ($port.BytesToWrite -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($port.BytesToWrite -gt 0) {
        throw "UART transmit queue did not drain"
    }

    $port.Write("stty echo; echo __VERIFY__; sha256sum $remoteScript; python3 -m py_compile $remoteScript; echo __TRANSFER_DONE__`r")
    $output = Read-SerialText -Port $port -Seconds 20 -Until '__TRANSFER_DONE__'
    Write-Output $output
    if ($output -notmatch $expectedSha256) {
        throw "Transferred script SHA-256 did not match"
    }
    if ($output -notmatch '__TRANSFER_DONE__') {
        throw "Board did not report transfer completion"
    }
    Write-Output 'SCRIPT_OK'
}
finally {
    if ($port.IsOpen) {
        try {
            $port.Write("stty echo`r")
            Start-Sleep -Milliseconds 100
        }
        catch {
            # Preserve the original transfer error, if any.
        }
        $port.Close()
    }
    $port.Dispose()
}
