param(
    [string]$ComPort = 'COM4'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localArchive = Join-Path $scriptDir 'deploy\input.txt.gz'
$remoteRoot = '/home/xilinx/pynq_z2_shared_work'
$remoteArchive = "$remoteRoot/input.txt.gz"
$remoteInput = "$remoteRoot/input.txt"

if ($remoteRoot -match '(?i)(^|/)loc(/|$)') {
    throw "Refusing protected destination: $remoteRoot"
}
if (-not (Test-Path -LiteralPath $localArchive -PathType Leaf)) {
    throw "Missing local archive: $localArchive"
}

$payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($localArchive))
$wrapped = [Text.StringBuilder]::new($payload.Length + 8192)
for ($offset = 0; $offset -lt $payload.Length; $offset += 76) {
    $count = [Math]::Min(76, $payload.Length - $offset)
    [void]$wrapped.Append($payload, $offset, $count)
    [void]$wrapped.Append("`r`n")
}

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

    $receiveCommand = "stty -echo; base64 -d > $remoteArchive`r`n"
    $port.Write($receiveCommand)
    Start-Sleep -Milliseconds 300
    $port.Write($wrapped.ToString())
    $port.Write([char]4)

    $deadline = (Get-Date).AddMinutes(2)
    while ($port.BytesToWrite -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if ($port.BytesToWrite -gt 0) {
        throw "UART transmit queue did not drain"
    }

    Start-Sleep -Milliseconds 500
    $verifyCommand = "stty echo; echo __VERIFY__; sha256sum $remoteArchive; gzip -t $remoteArchive && gzip -dk $remoteArchive; sha256sum $remoteInput; wc -c $remoteInput; echo __TRANSFER_DONE__`r`n"
    $port.Write($verifyCommand)

    $output = ''
    $verifyDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $verifyDeadline) {
        Start-Sleep -Milliseconds 250
        $output += $port.ReadExisting()
        if ($output -match '__TRANSFER_DONE__' -and $output -match 'xilinx@pynq') {
            break
        }
    }
    $output
    if ($output -notmatch '__TRANSFER_DONE__') {
        throw "Board did not report transfer completion"
    }
}
finally {
    if ($port.IsOpen) {
        $port.Close()
    }
    $port.Dispose()
}
