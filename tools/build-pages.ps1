# Builds the static, search-engine-friendly pages from site/data/aniimo.json:
#   site/abilities/<ability>/index.html   one "Best Aniimo for <ability>" page per Homeland ability
#   site/sitemap.xml                      every page, for Google Search Console
#   site/index.html                       the ability links between the abilities:start/end markers
#
#   powershell -ExecutionPolicy Bypass -File tools\build-pages.ps1
#
# tools/scrape.ps1 runs this automatically whenever it writes new data.
# Files are only rewritten when their content changed.
param(
    [string]$SiteDir = (Join-Path (Join-Path $PSScriptRoot '..') 'site'),
    [string]$BaseUrl = 'https://aniimocalc.com'
)

$ErrorActionPreference = 'Stop'
$SiteDir = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SiteDir))
$Utf8 = New-Object System.Text.UTF8Encoding $false

$dataText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $SiteDir 'data') 'aniimo.json'))
$data = $dataText | ConvertFrom-Json
# Read the date as raw text: PowerShell 7's ConvertFrom-Json turns it into a DateTime
$generated = [regex]::Match($dataText, '"generated":\s*"([^"]*)"').Groups[1].Value
$iconFile = @{}
$iconsPath = Join-Path (Join-Path $SiteDir 'icons') 'icons.json'
if (Test-Path $iconsPath) {
    ([System.IO.File]::ReadAllText($iconsPath) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $iconFile[$_.Name] = $_.Value }
}

function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function Get-Slug([string]$ability) { $ability.ToLower() }
function Get-Label($a) { if ($a.form) { "$($a.name) ($($a.form))" } else { $a.name } }
function Get-Level($a, [string]$ability) {
    $p = $a.abilities.PSObject.Properties[$ability]
    if ($p) { [int]$p.Value } else { 0 }
}
function Get-Icon([string]$name) {
    if ($iconFile.ContainsKey($name)) { "<img class=`"ico ico-img`" src=`"/icons/$($iconFile[$name])`" alt=`"`" width=`"20`" height=`"20`">" } else { '' }
}
function Get-Badge([string]$name, [int]$level) {
    "<span class=`"badge ab-$(Get-Slug $name)`" title=`"$name level $level`">$(Get-Icon $name)$name <b>$level</b></span>"
}
function Join-Names([string[]]$names) {
    if ($names.Count -le 1) { return ($names -join '') }
    ($names[0..($names.Count - 2)] -join ', ') + ' and ' + $names[-1]
}

# Writes a file only when its content changed, so unchanged data gives a clean git diff.
$script:written = 0
function Set-Page([string]$path, [string]$text) {
    $text = $text.Replace("`r`n", "`n")
    if ((Test-Path $path) -and [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n") -eq $text) { return }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, $Utf8)
    $script:written++
}

function Format-Page([string]$title, [string]$description, [string]$path, [string]$jsonLd, [string]$body) {
    $url = "$BaseUrl$path"
    @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$(Enc $title)</title>
  <meta name="description" content="$(Enc $description)">
  <link rel="canonical" href="$url">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/style.css">
  <meta name="theme-color" content="#3b7d5b">
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="Aniimo Homeland Calculator">
  <meta property="og:title" content="$(Enc $title)">
  <meta property="og:description" content="$(Enc $description)">
  <meta property="og:url" content="$url">
  <meta property="og:image" content="$BaseUrl/og-image.png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <script type="application/ld+json">$jsonLd</script>
</head>
<body>
$body
  <footer class="site">
    <p>Data from <a href="https://aniimotools.dev/creatures/" rel="noopener">AniimoTools</a>, updated $generated. Spotted a mistake? Open an issue on <a href="https://github.com/abyssalsoldier/aniimo-calc" rel="noopener">GitHub</a>.</p>
    <p>Aniimo, its creatures, names and game icons are the property of Pawprint Studio / FunPlus. This is an unofficial fan tool, not affiliated with or endorsed by them.</p>
  </footer>
</body>
</html>

"@
}

function Format-Row($a, [string]$ability) {
    $tags = ''
    if ($a.form -and -not ($a.prismana -and $a.form -eq 'Prismana')) { $tags += "<span class=`"form`"> $(Enc $a.form)</span>" }
    if ($a.prismana) { $tags += '<span class="prismana">Prismana</span>' }
    if ($a.unobtainable) { $tags += '<span class="tag" title="No wild spawn, evolution or egg">Unobtainable</span>' }
    $els = ($a.elements | ForEach-Object { "<span class=`"el ab-$(Get-Slug $_)`">$(Get-Icon $_)$_</span>" }) -join ''
    $others = @($a.abilities.PSObject.Properties | Where-Object { $_.Name -ne $ability } | Sort-Object @{ Expression = { -[int]$_.Value } }, Name)
    $otherHtml = if ($others) { ($others | ForEach-Object { Get-Badge $_.Name ([int]$_.Value) }) -join '' } else { '<span class="muted">None</span>' }
    $cls = if ($a.unobtainable) { ' class="unobtainable"' } else { '' }
    "          <tr$cls><td>$(Enc $a.name)$tags</td><td>$els</td><td>$otherHtml</td></tr>"
}

$all = @($data.aniimo)
$abilities = @($data.abilities)
$counts = @{}

foreach ($ability in $abilities) {
    $slug = Get-Slug $ability
    $path = "/abilities/$slug/"
    $with = @($all | Where-Object { (Get-Level $_ $ability) -gt 0 })
    $counts[$ability] = $with.Count
    $usable = @($with | Where-Object { -not $_.unobtainable })
    $regular = @($usable | Where-Object { -not $_.prismana })
    $bestRegular = if ($regular) { ($regular | ForEach-Object { Get-Level $_ $ability } | Measure-Object -Maximum).Maximum } else { 0 }
    $bestAny = if ($usable) { ($usable | ForEach-Object { Get-Level $_ $ability } | Measure-Object -Maximum).Maximum } else { 0 }

    # Best picks first: higher level, then catchable before Prismana before unobtainable,
    # then whoever brings the most other abilities along.
    $sortKeys = @(
        @{ Expression = { -(Get-Level $_ $ability) } },
        @{ Expression = { [int][bool]$_.unobtainable } },
        @{ Expression = { [int][bool]$_.prismana } },
        @{ Expression = { -(($_.abilities.PSObject.Properties | Measure-Object -Property Value -Sum).Sum) } },
        @{ Expression = { Get-Label $_ } }
    )
    $sorted = @($with | Sort-Object $sortKeys)
    $top = @($sorted | Where-Object { -not $_.unobtainable -and -not $_.prismana -and (Get-Level $_ $ability) -eq $bestRegular } | Select-Object -First 5 | ForEach-Object { Get-Label $_ })

    $title = "Best Aniimo for $ability in Homeland ($($with.Count) Aniimo ranked)"
    $description = if ($top) {
        "All $($with.Count) Aniimo with the $ability Homeland ability, ranked by level. Top picks: $((Join-Names $top)) (Lv $bestRegular). Plan your Homeland team for free."
    } else {
        "All $($with.Count) Aniimo with the $ability Homeland ability, ranked by level. Plan your Homeland team for free."
    }

    $levels = @($with | ForEach-Object { Get-Level $_ $ability } | Sort-Object -Unique -Descending)
    $byLevel = ($levels | ForEach-Object { $l = $_; "$(@($with | Where-Object { (Get-Level $_ $ability) -eq $l }).Count) at Lv $l" }) -join ', '
    $intro = "<p>$($with.Count) Aniimo and forms can work <strong>$ability</strong> in your Homeland: $byLevel."
    if ($top.Count -eq 1) { $intro += " The best one you can get without Prismana is $(Enc $top[0]) at Lv $bestRegular." }
    elseif ($top) { $intro += " The best ones you can get without Prismana are $(Enc (Join-Names $top)), all at Lv $bestRegular." }
    if ($bestAny -gt $bestRegular) {
        $pTop = @($sorted | Where-Object { -not $_.unobtainable -and $_.prismana -and (Get-Level $_ $ability) -eq $bestAny } | Select-Object -First 3 | ForEach-Object { Get-Label $_ })
        $intro += " Prismana forms go up to Lv ${bestAny}: $(Enc (Join-Names $pTop))."
    }
    $intro += '</p>'

    $sections = foreach ($l in $levels) {
        $rows = ($sorted | Where-Object { (Get-Level $_ $ability) -eq $l } | ForEach-Object { Format-Row $_ $ability }) -join "`n"
        @"
    <section class="card">
      <h2>$(Get-Icon $ability)Lv $l $ability</h2>
      <div class="table-wrap">
        <table class="list">
          <thead><tr><th>Aniimo</th><th>Elements</th><th>Other Homeland abilities</th></tr></thead>
          <tbody>
$rows
          </tbody>
        </table>
      </div>
    </section>
"@
    }

    $otherLinks = ($abilities | Where-Object { $_ -ne $ability } | ForEach-Object {
        "<a class=`"ab-link ab-$(Get-Slug $_)`" href=`"/abilities/$(Get-Slug $_)/`">$(Get-Icon $_)$_</a>"
    }) -join "`n        "

    $body = @"
  <header class="site">
    <p class="crumbs"><a href="/">Aniimo Homeland Calculator</a> &rsaquo; $ability</p>
    <h1 class="ab-$slug">$(Get-Icon $ability)Best Aniimo for $ability</h1>
    $intro
    <p><a class="cta" href="/?need=$ability">Build a team that covers $ability &rarr;</a></p>
    <p class="muted">The calculator finds the smallest team of Aniimo that covers $ability together with any other Homeland abilities you need.</p>
  </header>

  <main>
$($sections -join "`n")
    <section class="card">
      <h2>Other Homeland abilities</h2>
      <nav class="ab-links">
        $otherLinks
      </nav>
    </section>
  </main>
"@

    $jsonLd = ([ordered]@{
        '@context' = 'https://schema.org'
        '@type' = 'BreadcrumbList'
        itemListElement = @(
            [ordered]@{ '@type' = 'ListItem'; position = 1; name = 'Aniimo Homeland Calculator'; item = "$BaseUrl/" },
            [ordered]@{ '@type' = 'ListItem'; position = 2; name = "Best Aniimo for $ability"; item = "$BaseUrl$path" }
        )
    } | ConvertTo-Json -Depth 5 -Compress)

    Set-Page (Join-Path (Join-Path (Join-Path $SiteDir 'abilities') $slug) 'index.html') (Format-Page $title $description $path $jsonLd $body)
}

# Ability links on the calculator page
$indexPath = Join-Path $SiteDir 'index.html'
$index = [System.IO.File]::ReadAllText($indexPath)
$links = ($abilities | ForEach-Object {
    "<a class=`"ab-link ab-$(Get-Slug $_)`" href=`"abilities/$(Get-Slug $_)/`">$((Get-Icon $_).Replace('src="/', 'src="'))$_ <small>$($counts[$_])</small></a>"
}) -join "`n        "
$block = "<!-- abilities:start (generated by tools/build-pages.ps1) -->`n        $links`n        <!-- abilities:end -->"
$pattern = '<!-- abilities:start.*?<!-- abilities:end -->'
if (-not [regex]::IsMatch($index, $pattern, 'Singleline')) { throw "site/index.html has no <!-- abilities:start --> ... <!-- abilities:end --> markers" }
Set-Page $indexPath ([regex]::Replace($index.Replace("`r`n", "`n"), $pattern, { param($m) $block }, 'Singleline'))

# Sitemap
$urls = @("$BaseUrl/") + ($abilities | ForEach-Object { "$BaseUrl/abilities/$(Get-Slug $_)/" })
$sitemap = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<urlset xmlns=`"http://www.sitemaps.org/schemas/sitemap/0.9`">`n" +
    (($urls | ForEach-Object { "  <url><loc>$_</loc><lastmod>$generated</lastmod></url>" }) -join "`n") + "`n</urlset>`n"
Set-Page (Join-Path $SiteDir 'sitemap.xml') $sitemap

Write-Host "Built $($abilities.Count) ability pages and the sitemap ($script:written file(s) changed)."
