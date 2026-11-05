# Copies a file to the board over the serial console as gzip+base64, and checks its SHA-256 there.
# The board shell must be at a root prompt.
#   tools/serial-put.ps1 -Local build/board/probe -Remote /root/probe -Mode 755
param(
    [Parameter(Mandatory)][string]$Local,
    [Parameter(Mandatory)][string]$Remote,
    [string]$Mode = '644',
    [string]$Port = 'COM6',
    [int]$LinesPerPause = 20
)
$ErrorActionPreference = 'Stop'
$path = (Resolve-Path $Local).Path
$want = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
$raw = [IO.File]::ReadAllBytes($path)
$ms = New-Object IO.MemoryStream
$gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionLevel]::Optimal)
$gz.Write($raw, 0, $raw.Length); $gz.Close()
$b64 = [Convert]::ToBase64String($ms.ToArray())
$lines = for ($i = 0; $i -lt $b64.Length; $i += 76) { $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)) }

$enc = [Text.Encoding]::GetEncoding(28591)
$p = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$p.ReadBufferSize = 4194304
$p.Encoding = $enc
$p.Open()
$sb = New-Object Text.StringBuilder
try {
    [void]$p.ReadExisting()
    # Plain cat on a non-echoing tty. A bash heredoc goes through readline, which echoes every line
    # with a prompt and falls behind at full serial speed, dropping characters.
    $p.Write("stty -echo; cat > /tmp/put.b64; stty echo`n")
    Start-Sleep -Milliseconds 500
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = 0
    foreach ($l in $lines) {
        $p.Write($l + "`n")
        if (++$n % $LinesPerPause -eq 0) {
            # Let the line discipline drain; 115200 baud moves about 11 kB/s.
            while ($p.BytesToWrite -gt 0) { Start-Sleep -Milliseconds 5 }
            Start-Sleep -Milliseconds 20
            [void]$sb.Append($p.ReadExisting())
        }
    }
    while ($p.BytesToWrite -gt 0) { Start-Sleep -Milliseconds 5 }
    Start-Sleep -Milliseconds 300
    $p.Write([string][char]4)  # Ctrl-D at the start of a line ends cat
    Start-Sleep -Milliseconds 500
    $p.Write("base64 -d /tmp/put.b64 | gunzip > $Remote && chmod $Mode $Remote; rm -f /tmp/put.b64; sha256sum $Remote | sed 's/ .*/ SHA_END/; s/^/SHA_BEGIN /'; stty echo`n")
    $end = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $end) {
        [void]$sb.Append($p.ReadExisting())
        if ($sb.ToString() -match 'SHA_BEGIN ([0-9a-f]{64}) SHA_END') { break }
        Start-Sleep -Milliseconds 100
    }
} finally {
    $p.Close()
}
if ($sb.ToString() -notmatch 'SHA_BEGIN ([0-9a-f]{64}) SHA_END') { throw "No checksum from the board: $($sb.ToString())" }
$got = $Matches[1]
if ($got -ne $want) { throw "Checksum mismatch: local $want, board $got" }
"$Local -> $Remote, $($raw.Length) bytes ($($b64.Length) base64 chars) in $([int]$sw.Elapsed.TotalSeconds) s, SHA-256 matches"
