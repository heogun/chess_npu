# Writes the SD image to a removable disk and verifies it by reading it back. Run as Administrator.
# This erases the card. The disk number and exact size must both be given, so a changed disk
# number cannot silently select another device. Without -Confirmed it only prints the checks.
param(
    [Parameter(Mandatory)][int]$Disk,
    [Parameter(Mandatory)][long]$ExpectedBytes,
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string]$Sha256,
    [switch]$Confirmed
)
$ErrorActionPreference = 'Stop'

$d = Get-Disk -Number $Disk
if ($d.BusType -ne 'USB' -or $d.IsBoot -or $d.IsSystem) { throw "Disk $Disk is not a removable card" }
if ($d.Size -ne $ExpectedBytes) { throw "Disk $Disk has $($d.Size) bytes, expected $ExpectedBytes" }
$imageBytes = (Get-Item -LiteralPath $Image).Length
if ($imageBytes -gt $d.Size) { throw "Image of $imageBytes bytes does not fit" }
if ($imageBytes % 512 -ne 0) { throw 'Image size is not a whole number of sectors' }
$got = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
if ($got -ne $Sha256.ToLower()) { throw "Image hash $got, expected $Sha256" }
"target: disk $Disk, $($d.FriendlyName), $($d.Size) bytes"
"image: $imageBytes bytes, SHA-256 matches"
Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue | Select-Object PartitionNumber, DriveLetter, Type, Size | Format-Table -AutoSize | Out-String
if (-not $Confirmed) { 'Dry run, nothing written.'; return }

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VolumeLock {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, uint il, IntPtr o, uint ol, out uint r, IntPtr v);
    public static FileStream LockAndDismount(string letter) {
        var s = new FileStream(@"\\.\" + letter + ":", FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        uint r;
        // FSCTL_LOCK_VOLUME, then FSCTL_DISMOUNT_VOLUME. The lock lasts while the handle stays open.
        foreach (uint code in new uint[] { 0x90018, 0x90020 })
            if (!DeviceIoControl(s.SafeFileHandle, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero))
                throw new Win32Exception();
        return s;
    }
}
'@

$locks = @()
foreach ($p in Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue) {
    if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { $locks += [VolumeLock]::LockAndDismount([string]$p.DriveLetter) }
}
"locked and dismounted volumes: $($locks.Count)"
try {
    $buf = New-Object byte[] (4MB)
    $first = New-Object byte[] (4MB)
    $in = [IO.File]::OpenRead($Image)
    $out = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # The MBR goes last, so Windows does not rescan a half-written partition table.
    $firstLen = $in.Read($first, 0, $first.Length)
    $out.Position = $firstLen
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
    }
    $out.Flush($true)
    $out.Position = 0
    $out.Write($first, 0, $firstLen)
    $out.Flush($true)
    $out.Close(); $in.Close()
    "written in $([int]$sw.Elapsed.TotalSeconds) s"

    $sw.Restart()
    $back = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sha = [Security.Cryptography.SHA256]::Create()
    $left = $imageBytes
    while ($left -gt 0) {
        $n = $back.Read($buf, 0, [int][Math]::Min([long]$buf.Length, [long]$left))
        if ($n -le 0) { throw "Short read with $left bytes left" }
        [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
        $left -= $n
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
    $back.Close()
    $readback = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
    "read back in $([int]$sw.Elapsed.TotalSeconds) s: $readback"
    if ($readback -ne $got) { throw 'FAIL: read-back hash differs from the image' }
    'PASS: card contents match the image'
} finally {
    foreach ($l in $locks) { $l.Close() }
    Update-Disk -Number $Disk -ErrorAction SilentlyContinue
}
