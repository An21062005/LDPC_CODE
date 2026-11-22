param(
    [string]$ComPort = 'COM4'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$remoteFile = '/home/xilinx/pynq_z2_shared_work/output_fixed_full.txt'
$localFile = Join-Path $scriptDir 'output_fixed_full_board.txt'
$expectedSha256 = 'bf2ebae9981fee44a444dcf23682e3bd0f477e8446f81440bd87477487e81bd2'

if ($remoteFile -match '(?i)(^|/)loc(/|$)') {
    throw "Refusing protected source: $remoteFile"
}
if (Test-Path -LiteralPath $localFile) {
    $existingHash = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedSha256) {
        Write-Output "DOWNLOAD_OK: verified existing $localFile"
        return
    }
    throw "Refusing to overwrite existing local file: $localFile"
}

function Read-SerialText {
    param(
        [IO.Ports.SerialPort]$Port,
        [int]$Seconds,
        [string]$Until = ''
    )
    $text = [Text.StringBuilder]::new()
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        [void]$text.Append($Port.ReadExisting())
        if ($Until -and $text.ToString().Contains($Until)) { break }
    }
    return $text.ToString()
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

    if ($screen -match '(?i)login:\s*$') {
        $port.Write("xilinx`r")
        $screen = Read-SerialText -Port $port -Seconds 5 -Until 'Password:'
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

    $port.Write("stty -echo`r")
    Start-Sleep -Milliseconds 250
    $port.DiscardInBuffer()
    $port.Write("if test -f $remoteFile; then printf '__FILE_READY__\n'; sha256sum $remoteFile; printf '__CHECK_DONE__\n'; else printf '__FILE_MISSING__\n'; fi`r")
    $check = Read-SerialText -Port $port -Seconds 10 -Until '__CHECK_DONE__'
    if ($check -notmatch '__FILE_READY__') {
        throw "Board output file was not found: $remoteFile"
    }
    if ($check -notmatch $expectedSha256) {
        throw "Board output SHA-256 is not the expected passing result"
    }

    Write-Output 'Downloading verified board result over COM4...'
    $port.DiscardInBuffer()
    $port.Write("printf '__DL_BEGIN__\n'; gzip -c -- $remoteFile | base64 -w 76; printf '\n__DL_END__\n'`r")
    $received = Read-SerialText -Port $port -Seconds 180 -Until '__DL_END__'

    $beginMarker = '__DL_BEGIN__'
    $endMarker = '__DL_END__'
    $beginIndex = $received.IndexOf($beginMarker)
    if ($beginIndex -lt 0) {
        throw 'Download start marker was not received'
    }
    $dataStart = $beginIndex + $beginMarker.Length
    $endIndex = $received.IndexOf($endMarker, $dataStart)
    if ($endIndex -lt 0) {
        throw 'Download did not finish before the timeout'
    }
    $base64Text = $received.Substring($dataStart, $endIndex - $dataStart) -replace '\s', ''
    $compressedBytes = [Convert]::FromBase64String($base64Text)

    $compressedInput = [IO.MemoryStream]::new($compressedBytes)
    $gzip = [IO.Compression.GZipStream]::new(
        $compressedInput,
        [IO.Compression.CompressionMode]::Decompress
    )
    $outputStream = [IO.File]::Open(
        $localFile,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $gzip.CopyTo($outputStream)
    }
    finally {
        $outputStream.Dispose()
        $gzip.Dispose()
        $compressedInput.Dispose()
    }

    $localHash = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($localHash -ne $expectedSha256) {
        throw "Downloaded file SHA-256 did not match; file was preserved for inspection: $localFile"
    }
    Write-Output "DOWNLOAD_OK: $localFile"
    Write-Output "SHA256=$localHash"
}
finally {
    if ($port.IsOpen) {
        try {
            $port.Write("stty echo`r")
            Start-Sleep -Milliseconds 100
        }
        catch {
            # Preserve the original download error, if any.
        }
        $port.Close()
    }
    $port.Dispose()
}
