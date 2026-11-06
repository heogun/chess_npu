# Full flow for the measurement board. Run from any directory:
#   powershell -ExecutionPolicy Bypass -File hw\quartus\board\build.ps1 [-Design probe|nnue] [-From qsys|project|map|pins|compile|rbf]
# Order follows the HPS SDRAM flow: Analysis & Synthesis, then the generated pin-assignment
# script under quartus_sta, then the full compile. Logs go to build\board\logs.
param(
    [ValidateSet('probe', 'nnue')][string]$Design = 'probe',
    [ValidateSet('qsys', 'project', 'map', 'pins', 'compile', 'rbf')][string]$From = 'qsys'
)
$ErrorActionPreference = 'Stop'

$env:QUARTUS_ROOTDIR = 'C:\altera_lite\25.1std\quartus'
$bin = "$env:QUARTUS_ROOTDIR\bin64"
$sopc = "$env:QUARTUS_ROOTDIR\sopc_builder\bin"
$here = $PSScriptRoot
$repo = (Resolve-Path "$here\..\..\..").Path
$suffix = if ($Design -eq 'nnue') { '_nnue' } else { '' }
$logs = "$repo\build\board\logs$suffix"
$proj = "$repo\build\board\quartus$suffix"
New-Item -ItemType Directory -Force $logs | Out-Null

$steps = 'qsys', 'project', 'map', 'pins', 'compile', 'rbf'
$start = [array]::IndexOf($steps, $From)

function Run($name, $dir, $exe, [string[]]$arguments) {
    Write-Host "== $name"
    Push-Location $dir
    # Windows PowerShell turns native stderr lines into errors; judge by the exit code instead.
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Out-File -Encoding utf8 "$logs\$name.log"
        $code = $LASTEXITCODE
    } finally { Pop-Location; $ErrorActionPreference = 'Stop' }
    if ($code -ne 0) { throw "$name failed (exit $code), see $logs\$name.log" }
}

if ($start -le 0) {
    Run 'qsys_script' $here "$sopc\qsys-script.exe" @('--script=soc.tcl')
    $notApplied = Select-String -Path "$logs\qsys_script.log" -Pattern 'HPS parameters not applied: (.*)$'
    if (-not $notApplied -or $notApplied.Matches[0].Groups[1].Value.Trim()) {
        throw "HPS parameters not applied, see $logs\qsys_script.log"
    }
    if (Test-Path "$repo\build\board\soc") { Remove-Item -Recurse -Force "$repo\build\board\soc" }
    Run 'qsys_generate' $here "$sopc\qsys-generate.exe" @('soc.qsys', '--synthesis=VERILOG',
        "--output-directory=$repo\build\board\soc", '--family=Cyclone V', '--part=5CSEMA5F31C6')
}
if ($start -le 1) { Run 'project' $here "$bin\quartus_sh.exe" @('-t', "$here\project.tcl", $Design) }
if ($start -le 2) { Run 'map' $proj "$bin\quartus_map.exe" @('board') }
if ($start -le 3) {
    $tcl = Get-ChildItem -Recurse "$repo\build\board\soc" -Filter '*_pin_assignments.tcl'
    if ($tcl.Count -ne 1) { throw "expected one *_pin_assignments.tcl, found $($tcl.Count)" }
    Run 'pins' $proj "$bin\quartus_sta.exe" @('-t', $tcl[0].FullName, 'board')
}
if ($start -le 4) { Run 'compile' $proj "$bin\quartus_sh.exe" @('--flow', 'compile', 'board') }
# Uncompressed .rbf for U-Boot `fpga load`: with MSEL = 00000 (FPP x16) the FPGA expects
# uncompressed data, and quartus_cpf leaves compression off unless asked.
if ($start -le 5) { Run 'rbf' $proj "$bin\quartus_cpf.exe" @('-c', 'board.sof', 'board.rbf') }
Write-Host 'done'
