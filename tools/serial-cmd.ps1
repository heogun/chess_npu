# Sends lines to the board's serial console and prints what comes back until a pattern matches.
# Everything received is also appended to -Log, which is the record of the session.
#   tools/serial-cmd.ps1 -Send 'printenv bootcmd' -Until '=> $' -Seconds 5
param(
    [string[]]$Send = @(),
    [string]$Until = '',
    [int]$Seconds = 10,
    [string]$Port = 'COM6',
    [string]$Log = ''
)
$enc = [Text.Encoding]::GetEncoding(28591)
$p = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$p.ReadBufferSize = 4194304
$p.Encoding = $enc
$p.NewLine = "`n"
$p.Open()
$sb = New-Object Text.StringBuilder
function Drain {
    $s = $p.ReadExisting()
    if ($s.Length) {
        [void]$sb.Append($s)
        if ($Log) { [IO.File]::AppendAllText($Log, $s, $enc) }
    }
}
try {
    Start-Sleep -Milliseconds 100
    Drain
    foreach ($line in $Send) {
        $p.Write($line + "`n")
        Start-Sleep -Milliseconds 200
        Drain
    }
    $end = (Get-Date).AddSeconds($Seconds)
    $matched = $false
    while ((Get-Date) -lt $end) {
        Drain
        if ($Until -and ($sb.ToString() -match $Until)) { $matched = $true; break }
        Start-Sleep -Milliseconds 100
    }
    Drain
} finally {
    $p.Close()
}
($sb.ToString() -replace "`r", '')
if ($Until) { "[serial-cmd: matched=$matched]" }
