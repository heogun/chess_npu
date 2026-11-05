$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lock = Get-Content -LiteralPath (Join-Path $root 'config/stockfish.lock.json') -Raw | ConvertFrom-Json
$destination = Join-Path $root 'third_party/stockfish'
if (!(Test-Path -LiteralPath $destination)) {
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    git clone --depth 1 --branch $lock.tag $lock.repository $destination
    if ($LASTEXITCODE -ne 0) { throw 'Official source download failed' }
}
$actual = git -C $destination rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $lock.commit) { throw "Stockfish commit mismatch: $actual" }
$changes = git -C $destination status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Upstream tracked source has local modifications' }
Write-Output "Verified Stockfish $($lock.tag): $actual"
