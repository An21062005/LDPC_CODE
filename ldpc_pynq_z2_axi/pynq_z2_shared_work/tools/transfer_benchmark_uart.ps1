param(
    [string]$ComPort = 'COM4',
    [switch]$IncludeInput # Lenh cu van dung duoc; nay gui tat ca file trong SourceFolder.
)

# CAU HINH: THU MUC NGUON WINDOWS -> THU MUC DICH TREN BOARD.
$SourceFolder = 'C:\Users\HOANG AN\Downloads\ldpc_pynq_z2_axi\pynq_z2_shared_work\board_uploads'
$DestinationFolder = '/home/xilinx/pynq_z2_shared_work'
# Gui tat ca file truc tiep trong SourceFolder, khong gui thu muc con.

$ErrorActionPreference = 'Stop'
$SourceFolder = [IO.Path]::GetFullPath($SourceFolder)
if ($SourceFolder -match '(?i)(^|[\\/])loc([\\/]|$)') { throw 'Protected upload source' }
$checkPath = $SourceFolder
while ($checkPath) {
    $item = Get-Item -LiteralPath $checkPath -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing redirected or invalid source folder: $checkPath"
    }
    $checkPath = Split-Path -Parent $checkPath
}
$sourceFiles = @(Get-ChildItem -LiteralPath $SourceFolder -Force)
if ($sourceFiles.Count -eq 0) { throw 'SourceFolder has no files' }
$records = [Collections.Generic.List[object]]::new()
foreach ($file in $sourceFiles) {
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Name -ieq 'loc' -or $file.Name -match '[\\/]' -or $file.Name -in @('.','..')) {
        throw "SourceFolder must contain only regular files: $($file.FullName)"
    }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $records.Add(@{name=$file.Name; size=$bytes.Length; sha256=$hash; data=[Convert]::ToBase64String($bytes)})
}
$bundle = @{files=@($records.ToArray())} | ConvertTo-Json -Depth 5 -Compress
$bundleBytes = [Text.Encoding]::UTF8.GetBytes($bundle)
$stream = [IO.MemoryStream]::new()
$gzip = [IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Compress,$true)
try { $gzip.Write($bundleBytes,0,$bundleBytes.Length) }
finally { $gzip.Dispose() }
$payload = [Convert]::ToBase64String($stream.ToArray())
$stream.Dispose()
Write-Output "WINDOWS_SOURCE=$SourceFolder"

# Preflight all destinations before writing any board file.
$receiver = @'
import base64,gzip,hashlib,json,sys
from pathlib import Path
root=Path(DESTINATION_FOLDER_PLACEHOLDER)
def require(ok,message):
 if not ok: raise RuntimeError(message)
work=next((p for p in (root,*root.parents) if p.name=="pynq_z2_shared_work"),None)
require(work is not None,"Destination must be inside pynq_z2_shared_work")
require(root.resolve(strict=True)==root and root.is_dir(),"Unsafe destination folder")
require(all(p.lower()!="loc" for p in root.parts),"Protected destination")
require(any(p.name.lower()=="loc" for p in work.parent.iterdir()),"Loc sibling not confirmed")
print("BOARD_WRITE_ROOT="+str(root),flush=True)
print("PARENT_ENTRIES="+", ".join(sorted(p.name for p in work.parent.iterdir())),flush=True)
print("DESTINATION_ENTRIES="+", ".join(sorted(p.name for p in root.iterdir())),flush=True)
print("BENCHMARK_RECEIVER_READY",flush=True)
packet=json.loads(gzip.decompress(base64.b64decode(sys.stdin.read())))
require(isinstance(packet.get("files"),list) and len(packet["files"])>0,"Empty or invalid file packet")
incoming={}
names=set()
print("EXACT_UPLOAD_DESTINATIONS:",flush=True)
for record in packet["files"]:
 name=record["name"]
 require(isinstance(name,str) and bool(name) and name not in (".","..") and "/" not in name and "\\" not in name and "\x00" not in name,"Unsafe file name")
 require(name.lower()!="loc" and name.lower() not in names,"Protected or duplicate file name")
 names.add(name.lower())
 data=base64.b64decode(record["data"],validate=True)
 require(len(data)==record["size"] and hashlib.sha256(data).hexdigest()==record["sha256"],"Transfer checksum mismatch: "+name)
 p=root/name
 print(str(p),flush=True)
 require(not p.is_symlink(),"Refusing destination symlink: "+name)
 if p.exists():
  require(p.is_file() and p.resolve(strict=True)==p,"Unsafe existing destination: "+name)
  require(p.read_bytes()==data,"Refusing to overwrite different existing file: "+name)
 incoming[name]=data
for name,data in incoming.items():
 p=root/name
 if not p.exists():
  with p.open("xb") as f: f.write(data)
 require(p.read_bytes()==data,"Saved file mismatch: "+name)
 print("VERIFIED "+name+" SHA256="+hashlib.sha256(data).hexdigest(),flush=True)
print("FILES_SENT="+str(len(incoming)),flush=True)
print("FINAL_ENTRIES="+", ".join(sorted(p.name for p in root.iterdir())),flush=True)
print("BOARD_SEND_ALL_OK",flush=True)
'@
$receiver = $receiver.Replace('DESTINATION_FOLDER_PLACEHOLDER',(ConvertTo-Json -InputObject $DestinationFolder -Compress))
$receiverBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($receiver))
# Keep each terminal input line below the Linux canonical input limit.
$wrappedCode = [regex]::Replace($receiverBase64,'.{1,76}','$0' + [char]13)
$command = 'python3 -u -c ''import base64; exec(base64.b64decode("""' + $wrappedCode + '"""))'''

function Read-Until {
    param($Port, [string]$Pattern, [int]$Seconds = 15)
    $buffer = ''
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $buffer += $Port.ReadExisting()
        if ($buffer -match $Pattern) { return $buffer }
    }
    return $buffer
}

$port = [IO.Ports.SerialPort]::new($ComPort,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$port.Handshake = [IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.WriteTimeout = 5000
$echoDisabled = $false
try {
    try { $port.Open() }
    catch { throw "Cannot open $ComPort. Close MobaXterm and all other serial sessions, then retry. $($_.Exception.Message)" }
    $port.Write("`r")
    $screen = Read-Until $port '(?m)[#$]\s*$' 5
    if ($screen -notmatch '(?m)[#$]\s*$') {
        throw 'Linux shell is not ready. Log in through MobaXterm, close its COM tab, then retry.'
    }
    $port.Write("stty -echo; printf '__UART_%s__\n' READY`r")
    $echoDisabled = $true
    $ready = Read-Until $port '__UART_READY__' 5
    if ($ready -notmatch '__UART_READY__') { throw 'Shell did not acknowledge UART transfer' }
    # A quoted multiline argument preserves Python indentation on the board.
    $port.Write($command + "`r")
    $check = Read-Until $port 'BENCHMARK_RECEIVER_READY|Traceback|sudo:' 15
    Write-Output $check
    if ($check -notmatch 'BENCHMARK_RECEIVER_READY' -or $check -match 'Traceback') {
        throw 'Safe destination check failed; no script upload started'
    }
    $wrapped = [Text.StringBuilder]::new()
    for ($offset=0; $offset -lt $payload.Length; $offset+=76) {
        $count = [Math]::Min(76,$payload.Length-$offset)
        [void]$wrapped.Append($payload.Substring($offset,$count)).Append("`r")
    }
    $transferText = $wrapped.ToString()
    $lastProgress = -1
    for ($offset=0; $offset -lt $transferText.Length; $offset+=1024) {
        $count = [Math]::Min(1024,$transferText.Length-$offset)
        $port.Write($transferText.Substring($offset,$count))
        Start-Sleep -Milliseconds 10
        $progress = [int][Math]::Floor(10*($offset+$count)/$transferText.Length)
        if ($progress -gt $lastProgress) { Write-Output "Sending bundle: $($progress*10)%"; $lastProgress=$progress }
    }
    # EOF at an empty canonical input line finishes stdin; it does not log out.
    $port.Write([string][char]4)
    $result = Read-Until $port 'BOARD_SEND_ALL_OK|BENCHMARK_TRANSFER_OK|Traceback|(?m:[#$]\s*$)' 30
    Write-Output $result
    if ($result -notmatch 'BOARD_SEND_ALL_OK' -or $result -match 'Traceback') {
        throw 'Transfer not verified. Inspect the printed error.'
    }
    foreach ($record in $records) {
        if ($result -notmatch [regex]::Escape($record.sha256)) { throw "Missing verification for $($record.name)" }
    }
    Write-Output 'Done. Reopen COM in MobaXterm. The benchmark has NOT been executed.'
}
finally {
    if ($port.IsOpen) {
        if ($echoDisabled) {
            # Interrupt an incomplete receiver before restoring terminal echo.
            $port.Write([string][char]3)
            Start-Sleep -Milliseconds 200
            $port.Write("stty echo`r")
            Start-Sleep -Milliseconds 200
        }
        $port.Close()
    }
    $port.Dispose()
}
