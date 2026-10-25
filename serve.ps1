# Minimal static file server for the calculator. No installs, no admin rights.
# Usage: powershell -ExecutionPolicy Bypass -File serve.ps1 [-Port 8080] [-ListenAddress 127.0.0.1] [-PullHours 6]
# The port can also come from the ANIIMO_PORT environment variable.
# While running, it does a `git pull` every -PullHours hours (0 = never) so new Aniimo
# data from GitHub shows up without a restart. Files are read fresh on every request.
param(
    [int]$Port = $(if ($env:ANIIMO_PORT) { [int]$env:ANIIMO_PORT } else { 8080 }),
    [string]$ListenAddress = '127.0.0.1',
    [double]$PullHours = 6
)

$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$Mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.webp' = 'image/webp'
    '.txt'  = 'text/plain; charset=utf-8'
}
# Only these top-level folders/files are served
$Public = @('index.html', 'style.css', 'js', 'data', 'tests', 'favicon.ico')

function Send-Response($stream, [int]$code, [string]$status, [string]$type, [byte[]]$body, [bool]$headOnly) {
    $head = "HTTP/1.1 $code $status`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`n" +
            "Cache-Control: no-cache`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if (-not $headOnly -and $body.Length) { $stream.Write($body, 0, $body.Length) }
}

function Resolve-RequestPath([string]$target) {
    $path = [System.Uri]::UnescapeDataString(($target -split '[?#]')[0])
    if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
    $rel = $path.TrimStart('/').Replace('/', '\')
    if ($rel.Split('\')[0] -notin $Public) { return $null }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
    # Block path traversal outside the site folder
    if (-not $full.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (Test-Path $full -PathType Container) { $full = Join-Path $full 'index.html' }
    if (Test-Path $full -PathType Leaf) { return $full }
    $null
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($ListenAddress), $Port)
try {
    $listener.Start()
} catch {
    Write-Host "Could not listen on ${ListenAddress}:$Port - is something else using that port? Try -Port <other>." -ForegroundColor Red
    exit 1
}
Write-Host "Aniimo Homeland Calculator running at http://localhost:$Port/  (Ctrl+C to stop)" -ForegroundColor Green

# ---- periodic `git pull` (runs in the background so requests aren't blocked) ----
$canPull = $PullHours -gt 0 -and (Test-Path (Join-Path $Root '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)
if ($PullHours -gt 0 -and -not $canPull) { Write-Host 'Auto-update off: not a git checkout, or git is not installed.' -ForegroundColor Yellow }
elseif ($canPull) { Write-Host "Auto-update: git pull every $PullHours hour(s)." }
$pull = $null
$nextPull = Get-Date   # pull once at startup
$pullOut = Join-Path ([System.IO.Path]::GetTempPath()) "aniimo-calc-pull-$Port.txt"

function Step-AutoPull {
    if (-not $script:canPull) { return }
    if ($script:pull) {
        if (-not $script:pull.HasExited) { return }
        $msg = ((Get-Content $script:pullOut, "$($script:pullOut).err" -ErrorAction SilentlyContinue) -join "`n").Trim()
        if ($script:pull.ExitCode -eq 0) {
            if ($msg -notmatch 'Already up to date') { Write-Host ("{0:HH:mm:ss} Updated from GitHub: {1}" -f (Get-Date), (($msg -split "`n") | Where-Object { $_ -match 'changed' } | Select-Object -Last 1)) -ForegroundColor Green }
        } else {
            Write-Host ("{0:HH:mm:ss} git pull failed (exit {1}): {2}" -f (Get-Date), $script:pull.ExitCode, $msg) -ForegroundColor Yellow
        }
        $script:pull = $null
    }
    if ((Get-Date) -ge $script:nextPull) {
        $script:nextPull = (Get-Date).AddHours($PullHours)
        $script:pull = Start-Process git -ArgumentList '-C', "`"$Root`"", 'pull', '--ff-only' -NoNewWindow -PassThru `
            -RedirectStandardOutput $script:pullOut -RedirectStandardError "$($script:pullOut).err"
        $null = $script:pull.Handle   # lets Windows PowerShell report ExitCode later
    }
}

try {
    while ($true) {
        Step-AutoPull
        # Poll so Ctrl+C is handled promptly
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 8192, $true)
            $requestLine = $reader.ReadLine()
            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }  # skip headers
            if (-not $requestLine) { continue }

            $parts = $requestLine.Split(' ')
            $method = $parts[0]
            $target = if ($parts.Count -gt 1) { $parts[1] } else { '/' }
            $code = 200

            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                $code = 405
                Send-Response $stream 405 'Method Not Allowed' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed')) $false
            } else {
                $file = Resolve-RequestPath $target
                if ($file) {
                    $ext = [System.IO.Path]::GetExtension($file).ToLower()
                    $type = if ($Mime.ContainsKey($ext)) { $Mime[$ext] } else { 'application/octet-stream' }
                    Send-Response $stream 200 'OK' $type ([System.IO.File]::ReadAllBytes($file)) ($method -eq 'HEAD')
                } else {
                    $code = 404
                    Send-Response $stream 404 'Not Found' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('Not found')) ($method -eq 'HEAD')
                }
            }
            Write-Host ("{0:HH:mm:ss} {1} {2} {3}" -f (Get-Date), $code, $method, $target)
        } catch {
            Write-Host "Request error: $_" -ForegroundColor Yellow
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    Write-Host 'Server stopped.'
}
