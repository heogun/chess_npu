$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
if ($root -ne 'C:\Users\Administrator\Documents\chess_npu') { throw 'Unexpected workspace' }
$snapshot = Join-Path $root 'archive/sf18-source-snapshot.zip'
New-Item -ItemType Directory -Force (Split-Path $snapshot) | Out-Null
Add-Type -AssemblyName System.IO.Compression
$zip = [System.IO.Compression.ZipFile]::Open($snapshot, 'Create')
try {
  $roots = @('hw','docs','tools','.vscode','remove')
  foreach ($folder in $roots) {
    $base = Join-Path $root $folder
    if (!(Test-Path -LiteralPath $base)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $base -Recurse -File -Force) {
      $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\','/')
      # Preserve all source/configuration, including untracked work; exclude generated data.
      if ($relative -match '/(db|incremental_db|output_files|soc_system_generated|soc_system|hps_isw_handoff|\.qsys_edit|__pycache__)/') { continue }
      if ($file.Extension -in @('.img','.bak','.bin','.fat','.nnue','.pyc','.rpt','.sopcinfo','.csv')) { continue }
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relative) | Out-Null
    }
  }
  foreach ($name in @('README.md','.gitignore')) {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $name), $name) | Out-Null
  }
} finally { $zip.Dispose() }
$check = [System.IO.Compression.ZipFile]::OpenRead($snapshot)
try {
  if ($check.Entries.Count -lt 50) { throw 'Snapshot unexpectedly incomplete' }
  $entries = $check.Entries.FullName
  foreach ($required in @('hw/rtl/nnue/threat_delta_engine.sv','docs/PROGRESS.md','hw/sdimage/build_sdimage.py','hw/quartus/chess_npu.qsf','tools/g2_big_check.py')) {
    if ($required -notin $entries) { throw "Missing backup: $required" }
  }
  Write-Output "Verified source snapshot: $($check.Entries.Count) entries"
} finally { $check.Dispose() }
foreach ($name in @('hw','docs','tools','.vscode','remove')) {
  $target = [System.IO.Path]::GetFullPath((Join-Path $root $name))
  if (!( $target.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar))) { throw 'Target outside workspace' }
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}
Write-Output 'Removed obsolete SF18 workspace and generated artifacts; source snapshot retained.'
