# Reads the start of a removable card into an image file (a backup before tools/write-sd.ps1), then
# reads the card a second time and compares hashes. Run as Administrator. Nothing is written to the
# card. -Bytes defaults to the end of the last partition, so unused space is not copied.
#   tools\read-sd.ps1 -Disk 1 -ExpectedBytes 7914651648 -Image D:\backup.img
param(
    [Parameter(Mandatory)][int]$Disk,
    [Parameter(Mandatory)][long]$ExpectedBytes,
    [Parameter(Mandatory)][string]$Image,
    [long]$Bytes = 0
)
$ErrorActionPreference = 'Stop'
$d = Get-Disk -Number $Disk
if ($d.BusType -ne 'USB' -or $d.IsBoot -or $d.IsSystem) { throw "Disk $Disk is not a removable card" }
if ($d.Size -ne $ExpectedBytes) { throw "Disk $Disk has $($d.Size) bytes, expected $ExpectedBytes" }
if ($Bytes -eq 0) {
    $Bytes = (Get-Partition -DiskNumber $Disk | ForEach-Object { $_.Offset + $_.Size } | Measure-Object -Maximum).Maximum
}
if ($Bytes % 4MB -ne 0) { $Bytes = [long]([Math]::Ceiling($Bytes / 4MB) * 4MB) }
$Bytes = [Math]::Min($Bytes, $d.Size)
"source: disk $Disk $($d.FriendlyName), reading $Bytes of $($d.Size) bytes"
Get-Partition -DiskNumber $Disk | Select-Object PartitionNumber, Offset, Size, Type | Format-Table -AutoSize | Out-String

$buf = New-Object byte[] (4MB)
function Read-Card([IO.Stream]$copyTo) {
    $s = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sha = [Security.Cryptography.SHA256]::Create()
    $left = $Bytes
    while ($left -gt 0) {
        $n = $s.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
        if ($n -le 0) { throw "short read, $left left" }
        [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
        if ($copyTo) { $copyTo.Write($buf, 0, $n) }
        $left -= $n
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0); $s.Close()
    ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = [IO.File]::Create($Image)
try { $first = Read-Card $out } finally { $out.Close() }
"read in $([int]$sw.Elapsed.TotalSeconds) s: $first"
$sw.Restart()
$second = Read-Card $null
"second read in $([int]$sw.Elapsed.TotalSeconds) s: $second"
$file = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
if ($first -ne $second -or $file -ne $first) { throw "FAIL: reads differ (file $file)" }
"$first  $(Split-Path $Image -Leaf)" | Out-File -Encoding ascii "$Image.sha256"
'PASS: backup matches the card on two reads'
