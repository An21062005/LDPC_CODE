param(
    [string]$ComPort = 'COM4',
    [string]$RunDirectory = '' # Lenh cu van dung duoc; thuong chi sua SourceFolder.
)

# CAU HINH: THU MUC NGUON TREN BOARD -> THU MUC DICH WINDOWS.
$SourceFolder = '/home/xilinx/pynq_z2_shared_work/python_benchmark_20260729T052828_032205Z'
$DestinationFolder = 'C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\board_downloads'
# Lay tat ca file truc tiep trong SourceFolder, khong lay thu muc con.
# Moi lan tai tao thu muc con moi trong DestinationFolder.

$ErrorActionPreference = 'Stop'
if ($RunDirectory) {
    if ($RunDirectory -notmatch '^python_benchmark_[0-9]{8}T[0-9]{6}_[0-9]{6}Z$') { throw 'Invalid RunDirectory' }
    $SourceFolder = $SourceFolder.Substring(0,$SourceFolder.LastIndexOf('/')) + '/' + $RunDirectory
}
$sourceName = $SourceFolder.TrimEnd('/').Split('/')[-1]
if ($sourceName -notmatch '^[A-Za-z0-9_.-]+$' -or $sourceName -in @('.','..') -or $sourceName -ieq 'loc') {
    throw 'Unsafe source folder name'
}
$marker = [Guid]::NewGuid().ToString('N')
$beginMarker = "__BENCHMARK_BEGIN_$marker" + '__'
$endMarker = "__BENCHMARK_END_$marker" + '__'
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$DestinationFolder = [IO.Path]::GetFullPath($DestinationFolder)
$localFolder = Join-Path $DestinationFolder ($sourceName + '_download_' + $marker.Substring(0,8))
if ((Split-Path -Leaf $workspacePath) -ne 'pynq_z2_shared_work' -or
    -not $DestinationFolder.StartsWith($workspacePath + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    $localFolder -match '(?i)(^|[\\/])loc([\\/]|$)') {
    throw 'DestinationFolder must be inside this isolated pynq_z2_shared_work workspace'
}
$toolsItem = Get-Item -LiteralPath $PSScriptRoot -Force
if ($toolsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected tools folder' }
$checkPath = $DestinationFolder
while ($true) {
    if (Test-Path -LiteralPath $checkPath) {
        $item = Get-Item -LiteralPath $checkPath -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing redirected or invalid destination: $checkPath"
        }
    }
    if ($checkPath -eq $workspacePath) { break }
    $checkPath = Split-Path -Parent $checkPath
}
if (Test-Path -LiteralPath $localFolder) { throw "Refusing existing destination: $localFolder" }

# Read only: collect files from the configured board folder.
$sender = @'
import base64,gzip,hashlib,json
from pathlib import Path
folder=Path(SOURCE_FOLDER_PLACEHOLDER)
assert any(p.name=="pynq_z2_shared_work" for p in (folder,*folder.parents)), "Source must be inside pynq_z2_shared_work"
assert folder.resolve(strict=True)==folder and folder.is_dir(), "Unsafe source folder"
assert all(p.lower()!="loc" for p in folder.parts), "Protected source"
records=[]
for p in sorted(folder.iterdir()):
 assert p.name.lower()!="loc", "Protected source file"
 assert p.resolve(strict=True)==p and p.is_file(), "SourceFolder must contain only regular files: "+str(p)
 data=p.read_bytes()
 records.append(dict(name=p.name,size=len(data),sha256=hashlib.sha256(data).hexdigest(),data=base64.b64encode(data).decode("ascii")))
assert records, "SourceFolder has no files"
packet=json.dumps(dict(source=str(folder),files=records)).encode("ascii")
encoded=base64.b64encode(gzip.compress(packet)).decode("ascii")
print("BEGIN_MARKER_PLACEHOLDER",flush=True)
for i in range(0,len(encoded),76): print(encoded[i:i+76])
print("END_MARKER_PLACEHOLDER",flush=True)
'@
$sender = $sender.Replace('SOURCE_FOLDER_PLACEHOLDER',(ConvertTo-Json -InputObject $SourceFolder -Compress)).Replace('BEGIN_MARKER_PLACEHOLDER',$beginMarker).Replace('END_MARKER_PLACEHOLDER',$endMarker)
$senderBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sender))
$wrappedCode = [regex]::Replace($senderBase64,'.{1,76}','$0' + [char]13)
$command = 'python3 -u -c ''import base64; exec(base64.b64decode("""' + $wrappedCode + '"""))'''

function Read-Until {
    param($Port,[string]$Pattern,[int]$Seconds)
    $buffer = [Text.StringBuilder]::new()
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        [void]$buffer.Append($Port.ReadExisting())
        if ($buffer.Length -gt 4000000) { throw 'Unexpectedly large UART response' }
        if ($buffer.ToString() -match $Pattern) { return $buffer.ToString() }
    }
    throw 'Timed out waiting for board. Reopen MobaXterm and inspect the shell.'
}

$port = [IO.Ports.SerialPort]::new($ComPort,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$port.Handshake = [IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.ReadBufferSize = 1048576
$port.WriteTimeout = 5000
$echoDisabled = $false
try {
    try { $port.Open() }
    catch { throw "Cannot open $ComPort. Close all MobaXterm/other serial sessions, then retry. $($_.Exception.Message)" }
    $port.Write("`r")
    $screen = Read-Until $port '(?m)[#$]\s*$|(?i:login:|password:)\s*$' 10
    if ($screen -notmatch '(?m)[#$]\s*$') {
        throw 'Log in through MobaXterm until a Linux shell prompt appears, close that COM session, then retry.'
    }
    $port.Write("stty -echo; printf '__DOWNLOAD_%s__\n' READY`r")
    $echoDisabled = $true
    $null = Read-Until $port '__DOWNLOAD_READY__' 10
    Write-Output "BOARD_SOURCE=$SourceFolder"
    Write-Output 'Receiving files over UART; please wait...'
    $port.Write($command + "`r")
    $received = Read-Until $port ([regex]::Escape($endMarker) + '|Traceback') 180
    if ($received -match 'Traceback') { throw "Board could not read result files: $received" }
    $begin = $received.IndexOf($beginMarker)
    if ($begin -lt 0) { throw 'Missing packet start marker' }
    $start = $begin + $beginMarker.Length
    $end = $received.IndexOf($endMarker,$start)
    if ($end -lt 0) { throw 'Missing packet end marker' }
    $encoded = $received.Substring($start,$end-$start) -replace '\s',''
    $compressed = [Convert]::FromBase64String($encoded)
    $inputStream = [IO.MemoryStream]::new($compressed,$false)
    $gzip = [IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
    $decodedStream = [IO.MemoryStream]::new()
    try { $gzip.CopyTo($decodedStream); $json = [Text.Encoding]::UTF8.GetString($decodedStream.ToArray()) }
    finally { $gzip.Dispose(); $inputStream.Dispose(); $decodedStream.Dispose() }
    $packet = $json | ConvertFrom-Json
    if ($packet.source -ne $SourceFolder.TrimEnd('/') -or @($packet.files).Count -eq 0) {
        throw 'Unexpected packet source or file count'
    }
    $verified = @{}
    foreach ($record in $packet.files) {
        if ([string]::IsNullOrEmpty($record.name) -or $record.name -match '[\\/:*?"<>|\x00-\x1f]' -or $record.name -match '[. ]$' -or $record.name -in @('.','..') -or $record.name -ieq 'loc' -or $record.name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)' -or $verified.ContainsKey($record.name)) { throw 'Unexpected or duplicate file name' }
        $bytes = [Convert]::FromBase64String($record.data)
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        if ($bytes.Length -ne [long]$record.size -or $hash -ne $record.sha256) { throw "Checksum mismatch: $($record.name)" }
        $verified[$record.name] = $bytes
        Write-Output "VERIFIED $($record.name) bytes=$($bytes.Length) SHA256=$hash"
    }
    # All files are verified in RAM before any local result file is created.
    Write-Output "LOCAL_DESTINATION=$localFolder"
    if (-not (Test-Path -LiteralPath $DestinationFolder)) { $null = New-Item -ItemType Directory -Path $DestinationFolder }
    $null = New-Item -ItemType Directory -Path $localFolder
    foreach ($name in $verified.Keys) {
        $dest = Join-Path $localFolder $name
        $handle = [IO.File]::Open($dest,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $bytes = $verified[$name]; $handle.Write($bytes,0,$bytes.Length) }
        finally { $handle.Dispose() }
    }
    Write-Output 'BENCHMARK_DOWNLOAD_OK'
    Write-Output "Saved $($verified.Count) files in: $localFolder"
}
finally {
    if ($port.IsOpen) {
        if ($echoDisabled) {
            try {
                $port.Write([string][char]3)
                Start-Sleep -Milliseconds 200
                $port.Write("stty echo`r")
                Start-Sleep -Milliseconds 200
            } catch { }
        }
        $port.Close()
    }
    $port.Dispose()
}
