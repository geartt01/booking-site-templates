<#
  Local preview of the built sites in dist\ (Windows PowerShell 5.1, nothing to install).

  Usage, from the project folder:
    .\serve.cmd          then open http://localhost:8787/
  Stop with Ctrl+C.
#>
param([int]$Port = 8787)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist'))
$types = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8';
  '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg';
  '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon' }

function Send($ctx, [int]$status, [string]$type, [byte[]]$bytes) {
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers['Cache-Control'] = 'no-store'
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
function Text($s) { [Text.Encoding]::UTF8.GetBytes($s) }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving dist\ at http://localhost:$Port/  (Ctrl+C to stop)"
try {
  while ($listener.IsListening) {
    # Wait in short steps so Ctrl+C can stop the server.
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(250)) { }
    $ctx = $task.Result
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')

    if ($rel -eq '') {
      $sites = @(Get-ChildItem -Directory -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object { "<li><a href=""/$($_.Name)/"">$($_.Name)</a></li>" })
      Send $ctx 200 'text/html; charset=utf-8' (Text "<!doctype html><meta charset=utf-8><title>dist</title><h1>Built sites</h1><ul>$($sites -join '')</ul>")
      continue
    }

    $path = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Send $ctx 403 'text/plain' (Text 'Forbidden'); continue }
    if (Test-Path -LiteralPath $path -PathType Container) {
      if (-not $ctx.Request.Url.AbsolutePath.EndsWith('/')) {
        $ctx.Response.Redirect($ctx.Request.Url.AbsolutePath + '/'); $ctx.Response.Close(); continue
      }
      $path = Join-Path $path 'index.html'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Send $ctx 404 'text/plain' (Text "Not found: /$rel"); continue }

    $type = $types[[IO.Path]::GetExtension($path).ToLower()]
    if (-not $type) { $type = 'application/octet-stream' }
    Send $ctx 200 $type ([IO.File]::ReadAllBytes($path))
    Write-Host "  $($ctx.Request.HttpMethod) /$rel"
  }
} finally { $listener.Stop() }
