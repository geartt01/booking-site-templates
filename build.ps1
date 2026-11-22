<#
  Booking site builder (Windows PowerShell 5.1, nothing to install).

  Usage, from the project folder:
    .\build.cmd                  build every client in clients\
    .\build.cmd demo-klinika     build one client

  Reads clients\<slug>\config.json, puts it in place of the CONFIG block of the
  template named by "template" (clinic | salon | stay | shop), wraps the page in a
  full HTML document and writes dist\<slug>\index.html plus a Cloudflare Pages
  _headers file. Upload dist\<slug>\ to Cloudflare Pages to publish it.
#>
param([string]$Slug)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$templates = @{ clinic = 'clinic-template\index.html'; salon = 'salon-template\index.html'; stay = 'stay-template\index.html'; shop = 'shop-template\index.html' }
$langs = 'sq', 'en', 'de'

$headers = @'
/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: DENY
  Permissions-Policy: camera=(), microphone=(), geolocation=()
'@

function Has($obj, $name) { $null -ne $obj -and $obj.PSObject.Properties.Name -contains $name }
function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Str($v) { $v -is [string] -and $v.Trim() -ne '' }

# Every language in sq/en/de must be a non-empty string.
function Test-Langs($obj, $what, $errs) {
  foreach ($l in $langs) {
    if (-not (Has $obj $l) -or -not (Str $obj.$l)) { $errs.Add("$what is missing the ""$l"" text") }
  }
}

function Test-Config($cfg) {
  $e = New-Object System.Collections.Generic.List[string]
  if (-not (Has $cfg 'template') -or -not $templates.ContainsKey([string]$cfg.template)) {
    $e.Add('"template" must be "clinic", "salon", "stay" or "shop"'); return , $e
  }

  foreach ($k in 'name', 'address', 'phone', 'email', 'mapUrl', 'timeZone') {
    if (-not (Str $cfg.$k)) { $e.Add("missing ""$k""") }
  }
  if ($cfg.demo -isnot [bool]) { $e.Add('"demo" must be true or false') }
  $isStay = ([string]$cfg.template -eq 'stay')
  $isShop = ([string]$cfg.template -eq 'shop')
  if (-not $isStay -and -not $isShop -and ($cfg.slotMinutes -isnot [int] -or $cfg.slotMinutes -lt 5)) { $e.Add('"slotMinutes" must be a whole number of at least 5') }
  if ($cfg.retentionMonths -isnot [int] -or $cfg.retentionMonths -lt 1) { $e.Add('"retentionMonths" must be a whole number (used in the privacy notice)') }

  # A live site must be able to send the booking request, and must not still show example data.
  if ($cfg.demo -eq $false) {
    if ((([string]$cfg.whatsapp) -replace '\D', '').Length -lt 8) { $e.Add('a live site ("demo": false) needs "whatsapp" with the full number, e.g. "38344123456"') }
    foreach ($k in 'name', 'address', 'phone', 'email', 'mapUrl') {
      if ([string]$cfg.$k -match 'shembull|example|000 000|Rrezja|Studio Vela|Lugina|Lulishtja Bora|Rafti Vintage') { $e.Add("""$k"" still has example data: $($cfg.$k)") }
    }
  }

  # Guesthouses (template "stay") take stay requests by room and dates instead of hours and services.
  if ($isStay) {
    $rooms = @($cfg.rooms | Where-Object { $null -ne $_ })
    if ($rooms.Count -eq 0) { $e.Add('"rooms" needs at least one room') }
    $roomIds = @{}
    foreach ($r in $rooms) {
      $label = "room ""$($r.id)"""
      if ("$($r.id)" -notmatch '^[a-z0-9-]+$') { $e.Add("room id ""$($r.id)"" must use only a-z, 0-9 and -") }
      elseif ($roomIds.ContainsKey($r.id)) { $e.Add("room id ""$($r.id)"" is used twice") }
      else { $roomIds[$r.id] = $true }
      if ($r.guests -isnot [int] -or $r.guests -lt 1) { $e.Add("$label needs ""guests"" (the most people it sleeps)") }
      if ((Has $r 'price') -and -not (Str $r.price)) { $e.Add("$label has an empty ""price"" (remove it to hide the price)") }
      Test-Langs $r.n "$label name (n)" $e
      Test-Langs $r.d "$label description (d)" $e
    }
  }

  # Small shops (template "shop") list products in categories; orders go to WhatsApp.
  if ($isShop) {
    $catIds = @{}
    foreach ($c in @($cfg.categories | Where-Object { $null -ne $_ })) {
      if ("$($c.id)" -notmatch '^[a-z0-9-]+$') { $e.Add("category id ""$($c.id)"" must use only a-z, 0-9 and -") }
      else { $catIds[$c.id] = $true }
      Test-Langs $c.n "category ""$($c.id)"" name (n)" $e
    }
    $prods = @($cfg.products | Where-Object { $null -ne $_ })
    if ($prods.Count -eq 0) { $e.Add('"products" needs at least one product') }
    $pids = @{}
    foreach ($pr in $prods) {
      $label = "product ""$($pr.id)"""
      if ("$($pr.id)" -notmatch '^[a-z0-9-]+$') { $e.Add("product id ""$($pr.id)"" must use only a-z, 0-9 and -") }
      elseif ($pids.ContainsKey($pr.id)) { $e.Add("product id ""$($pr.id)"" is used twice") }
      else { $pids[$pr.id] = $true }
      if ((Has $pr 'price') -and -not ($pr.price -is [int] -or $pr.price -is [long] -or $pr.price -is [double] -or $pr.price -is [decimal])) { $e.Add("$label ""price"" must be a number, e.g. 25") }
      if ($catIds.Count -gt 0 -and -not $catIds.ContainsKey([string]$pr.cat)) { $e.Add("$label has unknown category ""$($pr.cat)""") }
      Test-Langs $pr.n "$label name (n)" $e
    }
  }

  if (-not $isStay) {
  # Opening hours: "0" (Sunday) to "6" (Saturday), each null or ["HH:MM","HH:MM"].
  $openDays = 0
  if (-not (Has $cfg 'hours')) { $e.Add('missing "hours"') }
  else {
    foreach ($d in 0..6) {
      if (-not (Has $cfg.hours "$d")) { $e.Add("""hours"" is missing day ""$d"" (use null for closed)"); continue }
      $h = $cfg.hours."$d"
      if ($null -eq $h) { continue }
      $h = @($h)
      if ($h.Count -ne 2 -or "$($h[0])" -notmatch '^\d\d:\d\d$' -or "$($h[1])" -notmatch '^\d\d:\d\d$' -or "$($h[0])" -ge "$($h[1])") {
        $e.Add("""hours"" day ""$d"" must be null or [""09:00"",""17:00""] with opening before closing")
      } else { $openDays++ }
    }
    if ($openDays -eq 0) { $e.Add('"hours" has no open day') }
  }

  # Services feed the booking flow. ids go into HTML attributes, so keep them simple.
  $svcs = @($cfg.services | Where-Object { $null -ne $_ })
  if ($svcs.Count -eq 0 -and -not $isShop) { $e.Add('"services" needs at least one service') }
  $ids = @{}
  foreach ($s in $svcs) {
    $label = "service ""$($s.id)"""
    if ("$($s.id)" -notmatch '^[a-z0-9-]+$') { $e.Add("service id ""$($s.id)"" must use only a-z, 0-9 and -") }
    elseif ($ids.ContainsKey($s.id)) { $e.Add("service id ""$($s.id)"" is used twice") }
    else { $ids[$s.id] = $true }
    if ($s.min -isnot [int] -or $s.min -lt 5) { $e.Add("$label needs ""min"" (minutes)") }
    if ((Has $s 'price') -and -not (Str $s.price)) { $e.Add("$label needs ""price"", e.g. ""EUR 15"" written with the euro sign") }
    Test-Langs $s.n "$label name (n)" $e
    Test-Langs $s.d "$label description (d)" $e
  }
  }

  foreach ($m in @($cfg.team | Where-Object { $null -ne $_ })) {
    if (-not (Str $m.i) -or $m.i.Length -gt 3) { $e.Add("team member ""$($m.i)"" needs ""i"": 1-3 initials") }
    if ((Has $m 'name') -and -not (Str $m.name)) { $e.Add("team member ""$($m.i)"" has an empty ""name"" (remove it to show the placeholder)") }
    Test-Langs $m.role "team member ""$($m.i)"" role" $e
  }

  if (Has $cfg 'text') {
    foreach ($l in $cfg.text.PSObject.Properties.Name) {
      if ($langs -notcontains $l) { $e.Add("""text"" has unknown language ""$l"" (use sq, en, de)") }
    }
  }
  return , $e
}

function Build-Client($slug) {
  if ($slug -notmatch '^[a-z0-9-]+$') { throw "client name ""$slug"" must use only a-z, 0-9 and -" }
  $cfgPath = Join-Path $root "clients\$slug\config.json"
  if (-not (Test-Path -LiteralPath $cfgPath)) { throw "no file clients\$slug\config.json" }

  $raw = [IO.File]::ReadAllText($cfgPath, $utf8).TrimStart([char]0xFEFF).Trim()
  try { $cfg = $raw | ConvertFrom-Json } catch { throw "clients\$slug\config.json is not valid JSON: $($_.Exception.Message)" }

  $errs = Test-Config $cfg
  # The config is pasted inside <script>; "</" could close it early.
  if ($raw.Contains('</')) { $errs.Add('config must not contain "</"') }
  if ($errs.Count) { throw ("clients\$slug\config.json:`n    - " + ($errs -join "`n    - ")) }

  $html = [IO.File]::ReadAllText((Join-Path $root $templates[[string]$cfg.template]), $utf8)
  $m = [regex]::Match($html, 'const CONFIG = \{[\s\S]*?\r?\n\};')
  if (-not $m.Success) { throw "CONFIG block not found in $($templates[[string]$cfg.template])" }
  $html = $html.Substring(0, $m.Index) + 'const CONFIG = ' + $raw + ';' + $html.Substring($m.Index + $m.Length)

  $title = if (Has $cfg 'title') { $cfg.title } else { $cfg.name }
  $html = [regex]::Replace($html, '<title>[^<]*</title>', ('<title>' + (Enc $title) + '</title>').Replace('$', '$$'))
  $html = $html -replace '<meta name="claude:viewport-fit-sides"[^>]*>\r?\n?', ''

  $meta = '<meta charset="utf-8">' + "`n" + '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
  if (Has $cfg 'description') {
    $html = $html -replace '<meta name="description"[^>]*>\r?\n?', ''
    $meta += "`n" + '<meta name="description" content="' + (Enc $cfg.description) + '">'
  }

  # Artifact pages have no <head>/<body>: everything up to </style> is head content.
  $cut = $html.IndexOf('</style>')
  if ($cut -lt 0) { throw 'template has no </style>' }
  $cut += '</style>'.Length
  $head = $html.Substring(0, $cut).Trim()
  $body = $html.Substring($cut).Trim()
  $page = "<!doctype html>`n<html lang=""sq"">`n<head>`n$meta`n$head`n</head>`n<body>`n$body`n</body>`n</html>`n"

  $out = Join-Path $root "dist\$slug"
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  [IO.File]::WriteAllText((Join-Path $out 'index.html'), $page, $utf8)
  [IO.File]::WriteAllText((Join-Path $out '_headers'), $headers, $utf8)

  $mode = if ($cfg.demo) { 'DEMO' } else { 'LIVE' }
  Write-Host ("  ok    {0,-22} {1,-8} {2,-5} -> dist\{0}\index.html" -f $slug, $cfg.template, $mode) -ForegroundColor Green
}

$slugs = if ($Slug) { @($Slug) } else {
  @(Get-ChildItem -Directory -LiteralPath (Join-Path $root 'clients') |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'config.json') } |
    ForEach-Object { $_.Name })
}
if ($slugs.Count -eq 0) { Write-Host 'No clients found in clients\ (each needs clients\<name>\config.json).'; exit 1 }

$failed = 0
foreach ($s in $slugs) {
  try { Build-Client $s }
  catch { $failed++; Write-Host "  FAIL  $s`n    $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host ("{0} built, {1} failed." -f ($slugs.Count - $failed), $failed)
if ($failed) { exit 1 }
