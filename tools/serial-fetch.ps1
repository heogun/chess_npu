# Copies a file from the board over the serial console as base64, and checks its SHA-256.
#   tools/serial-fetch.ps1 -Remote /root/h13.gz -Local build/h13.gz
param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$Local,
    [int]$Seconds = 400,
    [string]$Port = 'COM6'
)
$ErrorActionPreference = 'Stop'
$enc = [Text.Encoding]::GetEncoding(28591)
$p = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$p.ReadBufferSize = 8388608
$p.Encoding = $enc
$p.Open()
$sb = New-Object Text.StringBuilder
try {
    Start-Sleep -Milliseconds 200
    [void]$p.ReadExisting()
    $p.Write("stty -echo; sha256sum $Remote | sed 's/ .*/ SHA_END/; s/^/SHA_BEGIN /'; echo B64_BEGIN; base64 -w 76 $Remote; echo B64_END; stty echo`n")
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        [void]$sb.Append($p.ReadExisting())
        if ($sb.ToString() -match "`nB64_END") { break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 300
    [void]$sb.Append($p.ReadExisting())
} finally {
    $p.Close()
}
$text = $sb.ToString() -replace "`r", ''
if ($text -notmatch 'SHA_BEGIN ([0-9a-f]{64}) SHA_END') { throw 'No checksum in the output' }
$want = $Matches[1]
$m = [regex]::Match($text, "(?s)\nB64_BEGIN\n(.*?)\nB64_END")
if (-not $m.Success) { throw 'No complete base64 block in the output' }
$bytes = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
[IO.File]::WriteAllBytes((Join-Path (Get-Location) $Local), $bytes)
$got = (Get-FileHash -LiteralPath $Local -Algorithm SHA256).Hash.ToLower()
if ($got -ne $want) { throw "Checksum mismatch: board $want, local $got" }
"$Remote -> $Local, $($bytes.Length) bytes, SHA-256 matches"
