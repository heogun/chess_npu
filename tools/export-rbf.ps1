# Copies the Quartus FPGA image into a WSL build tree for tools/build-release.sh, with its provenance
# (board.rbf.json): SHA-256, Quartus version, project commit, resources, worst slacks, and the
# nnue_core map warnings 10030/10027 that must be checked before a board run.
#   powershell -ExecutionPolicy Bypass -File tools\export-rbf.ps1 [-Project build\board\quartus_nnue_w128]
#              [-Distro Ubuntu] [-Dest /home/<user>/chess_npu_build/release-inputs]
param(
    [string]$Project = 'build\board\quartus_nnue_w128',
    [string]$Distro = 'Ubuntu',
    [string]$Dest = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$proj = Join-Path $repo $Project
$rbf = Join-Path $proj 'board.rbf'
if (-not (Test-Path $rbf)) { throw "no $rbf" }
foreach ($f in 'board.fit.summary', 'board.sta.summary', 'board.map.rpt') {
    if ((Get-Item (Join-Path $proj $f)).LastWriteTime -gt (Get-Item $rbf).LastWriteTime) { throw "$f is newer than board.rbf" }
}
$fit = Get-Content (Join-Path $proj 'board.fit.summary')
function FitValue($key) { (($fit | Where-Object { $_ -like "$key*" }) -split ' : ', 2)[1] }
$slack = @{}
$sta = Get-Content (Join-Path $proj 'board.sta.summary')
for ($i = 0; $i -lt $sta.Count; $i++) {
    if ($sta[$i] -match "^Type\s+: (.*Model) (Setup|Hold) '(.*)'$") {
        $clock = if ($Matches[3] -like '*pll_0*') { 'core_100mhz' } elseif ($Matches[3] -like '*afi_clk*') { 'hps_sdram_afi' } else { $Matches[3] }
        $key = "$clock $($Matches[2].ToLower())"
        $value = [double](($sta[$i + 1] -split ': ')[1])
        if (-not $slack.ContainsKey($key) -or $value -lt $slack[$key]) { $slack[$key] = $value }
    }
}
# Warnings 10030/10027 that name nnue_core: the two known ones are listed in the board README.
$map = Get-Content (Join-Path $proj 'board.map.rpt')
$warn = @($map | Where-Object { $_ -match '\(1003[07]\)' -and $_ -match 'nnue_core' } | ForEach-Object { $_.Trim() })
$commit = (git -C $repo rev-parse HEAD).Trim()
$dirty = [bool](git -C $repo status --porcelain --untracked-files=no -- hw)
$info = [ordered]@{
    sha256 = (Get-FileHash $rbf -Algorithm SHA256).Hash.ToLower()
    bytes = (Get-Item $rbf).Length
    built = (Get-Item $rbf).LastWriteTime.ToString('s')
    quartus = FitValue 'Quartus Prime Version'
    device = FitValue 'Device'
    project_commit = $commit
    hw_tree_dirty = $dirty
    build_command = "hw\quartus\board\build.ps1 -Design nnue -Width 128"
    alms = FitValue 'Logic utilization'
    registers = FitValue 'Total registers'
    ram_blocks = FitValue 'Total RAM Blocks'
    block_memory_bits = FitValue 'Total block memory bits'
    dsp_blocks = FitValue 'Total DSP Blocks'
    worst_slack_ns = $slack
    nnue_core_map_warnings_10030_10027 = $warn
}
$json = $info | ConvertTo-Json -Depth 4
if (-not $Dest) {
    $home_ = (wsl.exe -d $Distro -- sh -c 'echo $HOME').Trim()
    $Dest = "$home_/chess_npu_build/release-inputs"
}
$unc = "\\wsl.localhost\$Distro" + ($Dest -replace '/', '\')
New-Item -ItemType Directory -Force $unc | Out-Null
Copy-Item $rbf (Join-Path $unc 'board.rbf')
[IO.File]::WriteAllText((Join-Path $unc 'board.rbf.json'), $json + "`n")
$json
"copied to ${Distro}:$Dest/board.rbf"
