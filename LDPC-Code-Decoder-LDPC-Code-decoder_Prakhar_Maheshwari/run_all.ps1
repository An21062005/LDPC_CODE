param(
    [string]$Python = "python",
    [string]$VivadoBin = ""
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if ($VivadoBin) {
    $env:VIVADO_BIN = $VivadoBin
}

Write-Host "[1/3] Generate RTL input and clean reference"
& $Python generate_input.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[2/3] Run corrected RTL with Vivado/XSim"
& $Python run_rtl.py --simulator vivado
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[3/3] Compare clean codewords with RTL output"
& $Python compare.py
exit $LASTEXITCODE
