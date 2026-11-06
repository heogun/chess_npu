# Reads one partition of a removable card to an image file, or writes back the 4 MiB chunks of an
# image that differ from the card, then verifies the whole partition by reading it back. Used to
# edit the ext4 root offline with debugfs, since WSL cannot attach USB card readers. Run as
# Administrator. The disk number and exact disk size must both be given.
param(
    [Parameter(Mandatory)][ValidateSet('read', 'write')][string]$Mode,
    [Parameter(Mandatory)][int]$Disk,
    [Parameter(Mandatory)][long]$ExpectedBytes,
    [Parameter(Mandatory)][int]$Partition,
    [Parameter(Mandatory)][string]$Image,
    [switch]$Confirmed
)
$ErrorActionPreference = 'Stop'

$d = Get-Disk -Number $Disk
if ($d.BusType -ne 'USB' -or $d.IsBoot -or $d.IsSystem) { throw "Disk $Disk is not a removable card" }
if ($d.Size -ne $ExpectedBytes) { throw "Disk $Disk has $($d.Size) bytes, expected $ExpectedBytes" }
$p = Get-Partition -DiskNumber $Disk -PartitionNumber $Partition
$offset = [long]$p.Offset; $size = [long]$p.Size
"target: disk $Disk $($d.FriendlyName), partition $Partition at $offset, $size bytes"

$chunk = 4MB
$buf = New-Object byte[] $chunk
$cur = New-Object byte[] $chunk
$sw = [Diagnostics.Stopwatch]::StartNew()

function Hash-Device {
    $s = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $s.Position = $offset
    $sha = [Security.Cryptography.SHA256]::Create()
    $left = $size
    while ($left -gt 0) {
        $n = $s.Read($buf, 0, [int][Math]::Min([long]$chunk, $left))
        if ($n -le 0) { throw "short read, $left left" }
        [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $left -= $n
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0); $s.Close()
    ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
}

if ($Mode -eq 'read') {
    $s = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $s.Position = $offset
    $out = [IO.File]::Create($Image)
    $left = $size
    while ($left -gt 0) {
        $n = $s.Read($buf, 0, [int][Math]::Min([long]$chunk, $left))
        if ($n -le 0) { throw "short read, $left left" }
        $out.Write($buf, 0, $n); $left -= $n
    }
    $out.Close(); $s.Close()
    "read in $([int]$sw.Elapsed.TotalSeconds) s"
    "image sha256: $((Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower())"
    return
}

if ((Get-Item -LiteralPath $Image).Length -ne $size) { throw 'image size differs from the partition' }
if (-not $Confirmed) { 'Dry run, nothing written.'; return }
$want = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VolumeLock2 {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, uint il, IntPtr o, uint ol, out uint r, IntPtr v);
    public static FileStream LockAndDismount(string letter) {
        var s = new FileStream(@"\\.\" + letter + ":", FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        uint r;
        foreach (uint code in new uint[] { 0x90018, 0x90020 })
            if (!DeviceIoControl(s.SafeFileHandle, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero))
                throw new Win32Exception();
        return s;
    }
    public static bool Same(byte[] a, byte[] b, int n) {
        for (int i = 0; i < n; i++) if (a[i] != b[i]) return false;
        return true;
    }
}
'@
$locks = @()
foreach ($q in Get-Partition -DiskNumber $Disk) {
    if ($q.DriveLetter -and $q.DriveLetter -ne [char]0) { $locks += [VolumeLock2]::LockAndDismount([string]$q.DriveLetter) }
}
try {
    $in = [IO.File]::OpenRead($Image)
    $dev = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $changed = 0; $pos = 0L
    while ($pos -lt $size) {
        $n = $in.Read($buf, 0, [int][Math]::Min([long]$chunk, $size - $pos))
        $dev.Position = $offset + $pos
        $m = $dev.Read($cur, 0, $n)
        if ($m -ne $n) { throw "short device read at $pos" }
        if (-not [VolumeLock2]::Same($buf, $cur, $n)) {
            $dev.Position = $offset + $pos
            $dev.Write($buf, 0, $n); $changed++
        }
        $pos += $n
    }
    $dev.Flush($true); $dev.Close(); $in.Close()
    "wrote $changed changed chunks of 4 MiB in $([int]$sw.Elapsed.TotalSeconds) s"
    $got = Hash-Device
    "read back: $got"
    if ($got -ne $want) { throw 'FAIL: partition differs from the image' }
    'PASS: partition matches the image'
} finally {
    foreach ($l in $locks) { $l.Close() }
    Update-Disk -Number $Disk -ErrorAction SilentlyContinue
}
