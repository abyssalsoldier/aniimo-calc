# Builds data/aniimo.json from metabot.gg creature pages.
# Usage: powershell -ExecutionPolicy Bypass -File tools\scrape.ps1 [-DelayMs 600]
param(
    [int]$DelayMs = 600,
    [string[]]$Only,   # optional creature slugs to fetch instead of the full index
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\aniimo.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Base = 'https://metabot.gg'
$UA = 'Mozilla/5.0 (aniimo-calc data builder)'
$S = [System.Text.RegularExpressions.RegexOptions]::Singleline

$Abilities = @('Fire','Water','Grass','Earth','Lightning','Ice','Wind','Dark','Light','Hauling','Artisanship','Leisure','Perfumery')
# Pages for things players can't get
$Unobtainable = @('lost-pathfinder', 'tuckin-90207')
# Site/game names that map onto our ability names
$AbilityAlias = @{ 'carry' = 'Hauling'; 'carrying' = 'Hauling'; 'rock' = 'Earth'; 'electric' = 'Lightning'; 'holy' = 'Light' }

function Get-Html([string]$url) {
    for ($try = 1; ; $try++) {
        try { return (Invoke-WebRequest $url -UserAgent $UA -UseBasicParsing).Content }
        catch {
            if ($try -ge 4) { throw }
            Start-Sleep -Seconds (3 * $try)
        }
    }
}

function Get-Text([string]$html) {
    $t = [regex]::Replace($html, '<svg.*?</svg>', '', $S)
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function ConvertTo-Ability([string]$name) {
    $n = $name.Trim()
    $key = $n.ToLower()
    if ($AbilityAlias.ContainsKey($key)) { return $AbilityAlias[$key] }
    foreach ($a in $Abilities) { if ($a.ToLower() -eq $key) { return $a } }
    Write-Warning "Unknown ability '$n'"
    $n
}

# "Wind 3, Water 2" -> @{ Wind = 3; Water = 2 }
function ConvertFrom-JobList([string]$text) {
    $jobs = [ordered]@{}
    foreach ($m in [regex]::Matches($text, '([A-Za-z][A-Za-z ]*?)\s*(?:Lv\.\s*)?(\d)')) {
        $jobs[(ConvertTo-Ability $m.Groups[1].Value)] = [int]$m.Groups[2].Value
    }
    $jobs
}

function Get-Cells([string]$row) {
    [regex]::Matches($row, '<td[^>]*>(.*?)</td>', $S) | ForEach-Object { $_.Groups[1].Value }
}

function Get-Creature([string]$path) {
    $html = Get-Html "$Base$path"
    $html = [regex]::Replace($html, '<script.*?</script>', '', $S)
    $slug = $path.Split('/')[-1]
    # Bosses, NPC-only entries and duplicate database pages can't be owned by players.
    # ("No wild spawn" alone isn't enough: e.g. Besauce comes from a fragment exchange.)
    $unobtainable = $slug -match 'boss' -or $slug -in $Unobtainable

    $h1 = [regex]::Match($html, '<h1.*?</h1>', $S).Value
    $name = [regex]::Match($h1, '<h1[^>]*>([^<]+)').Groups[1].Value.Trim()
    $name = [System.Net.WebUtility]::HtmlDecode($name)

    $results = @()

    # Multi-form creatures have a compare table with one column per form
    $table = [regex]::Match($html, '<table[^>]*>(?:(?!</table>).)*?<th scope="col">Form</th>.*?</table>', $S).Value
    if ($table) {
        $header = [regex]::Match($table, '<tr><th scope="col">Form</th>.*?</tr>', $S).Value
        $forms = [regex]::Matches($header, 'href="#form-([^"]+)">([^<]+)</a>') | ForEach-Object {
            @{ id = $_.Groups[1].Value; label = [System.Net.WebUtility]::HtmlDecode($_.Groups[2].Value.Trim()) }
        }
        $rows = @{}
        foreach ($r in [regex]::Matches($table, '<tr><th scope="row">([^<]+)</th>(.*?)</tr>', $S)) {
            $rows[$r.Groups[1].Value.Trim()] = @(Get-Cells $r.Groups[2].Value)
        }
        for ($i = 0; $i -lt $forms.Count; $i++) {
            $f = $forms[$i]
            $kind = if ($rows['Kind']) { Get-Text $rows['Kind'][$i] } else { '' }
            $elements = @()
            if ($rows['Element']) {
                $elements = @([regex]::Matches($rows['Element'][$i], 'elements/([a-z]+)') | ForEach-Object { ConvertTo-Ability $_.Groups[1].Value })
            }
            $jobs = if ($rows['Homeland jobs']) { ConvertFrom-JobList (Get-Text $rows['Homeland jobs'][$i]) } else { [ordered]@{} }
            $isDefault = $kind -match 'Default' -or $f.label -eq 'Basic'
            $results += [ordered]@{
                id        = $f.id
                page      = $slug
                name      = $name
                form      = if ($isDefault) { $null } else { $f.label }
                prismana  = [bool](($kind + ' ' + $f.label) -match 'Prismana')
                unobtainable = $false
                elements  = $elements
                abilities = $jobs
            }
        }
        return $results
    }

    # Single-form creature: elements from the header tags, jobs from the homeland section
    $headerTags = [regex]::Matches($html, '<a class="[^"]*_headerTag[^"]*"[^>]*href="/en/aniimo/elements/([a-z]+)"')
    $elements = @($headerTags | ForEach-Object { ConvertTo-Ability $_.Groups[1].Value } | Select-Object -Unique)
    $homeland = [regex]::Match($html, 'id="homeland".*?</section>', $S).Value
    $jobs = [ordered]@{}
    foreach ($m in [regex]::Matches($homeland, '_pipRow" href="/en/aniimo/homeland/[^"]+">([^<]+)<.*?Lv\.\s*(\d)</a>', $S)) {
        $jobs[(ConvertTo-Ability $m.Groups[1].Value)] = [int]$m.Groups[2].Value
    }
    @([ordered]@{
        id        = $slug
        page      = $slug
        name      = $name
        form      = $null
        prismana  = $false
        unobtainable = [bool]$unobtainable
        elements  = $elements
        abilities = $jobs
    })
}

if ($Only) { $paths = $Only -split ',' | ForEach-Object { "/en/aniimo/creatures/$_" } } else {
Write-Host 'Fetching creature index...'
$index = Get-Html "$Base/en/aniimo/creatures"
# The grid lazy-loads, so also read the full list from the page's structured data
$paths = [regex]::Matches($index, '(?:href="|metabot\.gg)(/en/aniimo/creatures/[a-z0-9\-]+)') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
}
Write-Host "Found $($paths.Count) creature pages"

$all = @()
$failed = @()
$n = 0
foreach ($p in $paths) {
    $n++
    try {
        $c = @(Get-Creature $p)
        $all += $c
        Write-Host ("[{0}/{1}] {2}: {3} form(s)" -f $n, $paths.Count, $c[0].name, $c.Count)
    } catch {
        Write-Warning "Failed $p : $_"
        $failed += $p.Split('/')[-1]
    }
    Start-Sleep -Milliseconds $DelayMs
}

# With -Only, replace just those pages inside the existing file
if ($Only -and (Test-Path $OutFile)) {
    $fetched = @($all | ForEach-Object { $_.page } | Select-Object -Unique)
    $existing = (Get-Content $OutFile -Raw | ConvertFrom-Json).aniimo | Where-Object { $_.page -notin $fetched }
    $all = @($existing) + $all
}

$out = [ordered]@{
    source    = "$Base/en/aniimo/creatures"
    generated = (Get-Date).ToString('yyyy-MM-dd')
    abilities = $Abilities
    aniimo    = @($all | Sort-Object { $_.name }, { [bool]$_.form }, { $_.form })
}
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
$json = $out | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Resolve-Path $dir).Path + '\' + (Split-Path $OutFile -Leaf), $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $($all.Count) entries to $OutFile"
if ($failed) { Write-Warning "Failed pages (rerun with -Only): $($failed -join ',')" }
