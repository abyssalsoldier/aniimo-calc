# Builds site/data/aniimo.json from aniimotools.dev creature pages, then applies tools/overrides.json.
#
#   powershell -ExecutionPolicy Bypass -File tools\scrape.ps1           # full refresh
#   powershell -ExecutionPolicy Bypass -File tools\scrape.ps1 -Only tromber,glacy
#
# The file is only rewritten when the data actually changed. The run aborts (exit 1)
# without writing anything if the scrape looks broken: failed pages, many entries
# vanishing, entries with nothing parsed, or an ability name it doesn't recognise.
# -Force skips those checks. -SummaryFile writes a Markdown summary of the changes.
# After writing, it runs tools/build-pages.ps1 to rebuild the ability pages and sitemap.
param(
    [int]$DelayMs = 600,
    [string[]]$Only,   # optional creature slugs to fetch instead of the full index
    [string]$OutFile = (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'site') 'data') 'aniimo.json'),
    [string]$OverridesFile = (Join-Path $PSScriptRoot 'overrides.json'),
    [string]$SummaryFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Resolve relative paths against the current PowerShell location (not .NET's working directory)
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$OverridesFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OverridesFile)
if ($SummaryFile) { $SummaryFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SummaryFile) }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Base = 'https://aniimotools.dev'
$UA = 'Mozilla/5.0 (aniimo-calc data builder)'
$S = [System.Text.RegularExpressions.RegexOptions]::Singleline

$Abilities = @('Fire','Water','Grass','Earth','Lightning','Ice','Wind','Dark','Light','Hauling','Artisanship','Leisure','Perfumery')
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

function ConvertTo-Ability([string]$name) {
    $n = $name.Trim()
    $key = $n.ToLower()
    if ($AbilityAlias.ContainsKey($key)) { return $AbilityAlias[$key] }
    foreach ($a in $Abilities) { if ($a.ToLower() -eq $key) { return $a } }
    $script:UnknownAbilities += $n
    $n
}

function Get-Elements([string]$html) {
    @([regex]::Matches($html, 'href="/elements/([a-z]+)/"') | ForEach-Object { ConvertTo-Ability $_.Groups[1].Value } | Select-Object -Unique)
}

# kit-list items -> @{ Lightning = 3; Artisanship = 3 }
function Get-Jobs([string]$html) {
    $jobs = [ordered]@{}
    foreach ($m in [regex]::Matches($html, 'kit-list__name">([^<]+)</span>\s*<span class="kit-list__lv[^"]*">Lv\.\s*(\d)', $S)) {
        $jobs[(ConvertTo-Ability ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)))] = [int]$m.Groups[2].Value
    }
    $jobs
}

function ConvertTo-Slug([string]$s) {
    ($s.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}

# Ids come from the names (the site's own form keys are sometimes opaque, e.g. "v1020302"):
# "Blazen" + "Prismana Form" -> "blazen-prismana". They're stored in visitors' owned lists,
# so a rename here needs an entry in RENAMED_IDS in site/js/app.js.
function Get-FormId([string]$name, [string]$form) {
    $id = ConvertTo-Slug $name
    if ($form) { $id += '-' + (ConvertTo-Slug ($form -replace '\s*Form$', '')) }
    $id
}

function Get-Creature([string]$path) {
    $html = Get-Html "$Base$path"
    $html = $html -replace ' data-astro-cid-[a-z0-9]+', ''
    $slug = $path.Trim('/').Split('/')[-1]
    $name = [System.Net.WebUtility]::HtmlDecode([regex]::Match($html, '<h1 class="hero__name">([^<]+)').Groups[1].Value.Trim())
    # Creatures outside the Aniilog (no dex number) are NPC/boss-only and can't be owned
    $dexline = [regex]::Match($html, '<p class="hero__dexline">.*?</p>', $S).Value
    $unobtainable = $dexline -notmatch 'No\.\d'

    # Homeland abilities: one kit per form whose kit differs from the default; a single
    # list when the creature has no such forms.
    $homeland = [regex]::Match($html, 'id="homeland".*?</section>', $S).Value
    $kits = @{}
    foreach ($k in [regex]::Matches($homeland, '<div data-kit-form="([^"]*)"[^>]*>(.*?)</ul>', $S)) {
        $kits[$k.Groups[1].Value] = Get-Jobs $k.Groups[2].Value
    }
    if (-not $kits.ContainsKey('')) { $kits[''] = Get-Jobs $homeland }

    # Forms come from the page's album data (one entry per form, default first)
    $album = [regex]::Match($html, '<script type="application/json" data-alb-data>(.*?)</script>', $S).Groups[1].Value
    $forms = if ($album) { @(($album | ConvertFrom-Json).D.forms) } else { @() }
    if (-not $forms) { $forms = @([pscustomobject]@{ key = ''; name = $name; prismana = $false }) }

    # Elements: hero badges for the default form, a badge template per form tab
    $elementsByKey = @{ '' = Get-Elements ([regex]::Match($html, '<span data-form-badges[^>]*>(.*?)</span>', $S).Groups[1].Value) }
    foreach ($t in [regex]::Matches($html, 'data-form-tab="(\d+)"[^>]*?data-form-key(?:="([^"]*)")?')) {
        $tpl = [regex]::Match($html, '<template data-form-badges-tpl="' + $t.Groups[1].Value + '">(.*?)</template>', $S).Groups[1].Value
        if ($tpl) { $elementsByKey[$t.Groups[2].Value] = Get-Elements $tpl }
    }

    foreach ($f in $forms) {
        $key = [string]$f.key
        $form = if ($key) { [System.Net.WebUtility]::HtmlDecode($f.name) } else { $null }
        # The name links to this form's tab on the AniimoTools page
        $wiki = "$Base/creatures/$slug/" + $(if ($key) { '#form=' + [uri]::EscapeDataString($key) })
        [ordered]@{
            id           = Get-FormId $name $form
            page         = $slug
            name         = $name
            form         = $form
            prismana     = [bool]$f.prismana
            unobtainable = $unobtainable
            elements     = if ($elementsByKey.ContainsKey($key)) { $elementsByKey[$key] } else { $elementsByKey[''] }
            abilities    = if ($kits.ContainsKey($key)) { $kits[$key] } else { $kits[''] }
            wiki         = $wiki
        }
    }
}


# ---------- JSON output (stable formatting: one Aniimo per line) ----------

function ConvertTo-JsonText($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
    if ($v -is [string]) {
        $sb = New-Object System.Text.StringBuilder '"'
        foreach ($ch in $v.ToCharArray()) {
            switch ($ch) {
                '"' { [void]$sb.Append('\"') }
                '\' { [void]$sb.Append('\\') }
                default {
                    if ([int]$ch -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) }
                }
            }
        }
        return $sb.Append('"').ToString()
    }
    if ($v -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $v.Keys) { (ConvertTo-JsonText ([string]$k)) + ':' + (ConvertTo-JsonText $v[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        $parts = foreach ($p in $v.PSObject.Properties) { (ConvertTo-JsonText $p.Name) + ':' + (ConvertTo-JsonText $p.Value) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($v -is [System.Collections.IEnumerable]) {
        return '[' + (@($v | ForEach-Object { ConvertTo-JsonText $_ }) -join ',') + ']'
    }
    ConvertTo-JsonText ([string]$v)
}

# Normalise any entry (fresh hashtable or one read back from JSON) to a fixed field order.
function ConvertTo-Entry($e) {
    $abilities = [ordered]@{}
    $src = $e.abilities
    $names = if ($src -is [System.Collections.IDictionary]) { @($src.Keys) } else { @($src.PSObject.Properties | ForEach-Object Name) }
    foreach ($k in $names) { $abilities[$k] = [int]$src.$k }
    [ordered]@{
        id           = [string]$e.id
        page         = [string]$e.page
        name         = [string]$e.name
        form         = if ($e.form) { [string]$e.form } else { $null }
        prismana     = [bool]$e.prismana
        unobtainable = [bool]$e.unobtainable
        elements     = @($e.elements | ForEach-Object { [string]$_ })
        abilities    = $abilities
        wiki         = [string]$e.wiki
    }
}

function Format-Abilities($e) {
    (@($e.abilities.Keys | ForEach-Object { "$_ $($e.abilities[$_])" }) -join ', ')
}

# ---------- main ----------

$script:UnknownAbilities = @()

if ($Only) { $paths = $Only -split ',' | ForEach-Object { "/creatures/$($_.Trim())/" } } else {
    Write-Host 'Fetching creature index...'
    $index = Get-Html "$Base/search-index.json" | ConvertFrom-Json
    # The site search index lists every creature page (once per name and per alias)
    $paths = @($index | Where-Object { $_.k -eq 'Aniimo' } | ForEach-Object { $_.h } | Select-Object -Unique)
}
Write-Host "Found $($paths.Count) creature pages"

$scraped = @()
$failed = @()
$n = 0
foreach ($p in $paths) {
    $n++
    try {
        $c = @(Get-Creature $p)
        $scraped += $c
        Write-Host ("[{0}/{1}] {2}: {3} form(s)" -f $n, $paths.Count, $c[0].name, $c.Count)
    } catch {
        Write-Warning "Failed $p : $_"
        $failed += $p.Split('/')[-1]
    }
    Start-Sleep -Milliseconds $DelayMs
}

$old = @()
$oldAbilities = $Abilities
if (Test-Path $OutFile) {
    $oldData = Get-Content $OutFile -Raw | ConvertFrom-Json
    $old = @($oldData.aniimo | ForEach-Object { ConvertTo-Entry $_ })
    if ($oldData.abilities) { $oldAbilities = @($oldData.abilities) }
}

$all = @($scraped | ForEach-Object { ConvertTo-Entry $_ })
# With -Only, keep every page that wasn't refetched
if ($Only) {
    $fetched = @($all | ForEach-Object { $_.page } | Select-Object -Unique)
    $all = @($old | Where-Object { $_.page -notin $fetched }) + $all
}

# Hand corrections: { "patch": { "<id>": { field: value, ... } } }
if (Test-Path $OverridesFile) {
    $ov = Get-Content $OverridesFile -Raw | ConvertFrom-Json
    if ($ov.patch) {
        foreach ($prop in $ov.patch.PSObject.Properties) {
            $entry = $all | Where-Object { $_.id -eq $prop.Name } | Select-Object -First 1
            if (-not $entry) { Write-Warning "Override for unknown id '$($prop.Name)' skipped"; continue }
            foreach ($field in $prop.Value.PSObject.Properties) {
                if ($field.Name -eq 'abilities') {
                    $entry.abilities = (ConvertTo-Entry ([pscustomobject]@{ abilities = $field.Value })).abilities
                } else {
                    $entry[$field.Name] = $field.Value
                }
            }
        }
    }
}
# Players can't own unobtainable Aniimo, so they're left out of the data entirely
$skipped = @($all | Where-Object { $_.unobtainable })
if ($skipped) { Write-Host "Left out $($skipped.Count) unobtainable: $(($skipped | ForEach-Object id) -join ', ')" }
$all = @($all | Where-Object { -not $_.unobtainable } | Sort-Object { $_.name }, { [bool]$_.form }, { $_.form }, { $_.id })

# ---------- sanity checks ----------

$problems = @()
if ($failed) { $problems += "$($failed.Count) page(s) failed to load: $($failed -join ', ')" }
if ($script:UnknownAbilities) {
    $problems += "Unrecognised ability name(s): $(($script:UnknownAbilities | Select-Object -Unique) -join ', '). If the game added a new ability, add it to `$Abilities in tools/scrape.ps1."
}
$empty = @($all | Where-Object { $_.abilities.Count -eq 0 -or $_.elements.Count -eq 0 -or -not $_.name })
if ($empty.Count -gt [Math]::Max(2, $all.Count * 0.05)) {
    $problems += "$($empty.Count) entries have no name, elements or abilities (page layout may have changed), e.g. $(($empty | Select-Object -First 5 | ForEach-Object id) -join ', ')"
}
$newIds = @($all | ForEach-Object id)
$removed = @($old | Where-Object { $_.id -notin $newIds })
if ($old.Count -and $removed.Count -gt [Math]::Max(3, $old.Count * 0.03)) {
    $problems += "$($removed.Count) existing entries would disappear, e.g. $(($removed | Select-Object -First 5 | ForEach-Object id) -join ', ')"
}
$dupes = @($newIds | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
if ($dupes) { $problems += "Duplicate ids: $($dupes -join ', ')" }

if ($problems) {
    $problems | ForEach-Object { Write-Host "PROBLEM: $_" -ForegroundColor Red }
    if (-not $Force) {
        Write-Host 'Nothing written. Fix the scraper or rerun with -Force to write anyway.' -ForegroundColor Red
        exit 1
    }
    Write-Warning '-Force given: writing despite the problems above.'
}

# ---------- diff and write ----------

$oldById = @{}; foreach ($e in $old) { $oldById[$e.id] = $e }
$added = @($all | Where-Object { -not $oldById.ContainsKey($_.id) })
$changed = @()
foreach ($e in $all) {
    $o = $oldById[$e.id]
    if ($o -and (ConvertTo-JsonText $o) -ne (ConvertTo-JsonText $e)) { $changed += , @($o, $e) }
}
$abilitiesChanged = ($oldAbilities -join ',') -ne ($Abilities -join ',')


$label = { param($e) if ($e.form) { "$($e.name) ($($e.form))" } else { $e.name } }
$summary = @("Aniimo data update: $($added.Count) added, $($changed.Count) changed, $($removed.Count) removed ($($all.Count) entries total)", '')
if ($added) {
    $summary += '### Added'
    $summary += $added | ForEach-Object { "- $(& $label $_)$(if ($_.prismana) { ' [Prismana]' }): $(Format-Abilities $_)" }
    $summary += ''
}
if ($changed) {
    $summary += '### Changed'
    $summary += $changed | ForEach-Object {
        $o, $e = $_
        $what = @()
        if ((Format-Abilities $o) -ne (Format-Abilities $e)) { $what += "abilities $(Format-Abilities $o) -> $(Format-Abilities $e)" }
        if (($o.elements -join '/') -ne ($e.elements -join '/')) { $what += "elements $($o.elements -join '/') -> $($e.elements -join '/')" }
        foreach ($k in 'name', 'form', 'prismana', 'unobtainable', 'page', 'wiki') { if ("$($o[$k])" -ne "$($e[$k])") { $what += "$k '$($o[$k])' -> '$($e[$k])'" } }
        "- $(& $label $e): $($what -join '; ')"
    }
    $summary += ''
}
if ($removed) {
    $summary += '### Removed'
    $summary += $removed | ForEach-Object { "- $(& $label $_) ($($_.id))" }
    $summary += ''
}
if ($abilitiesChanged) { $summary += "Ability list: $($Abilities -join ', ')"; $summary += '' }

function Format-DataFile([string]$generated) {
    "{`n" +
    "  `"source`": $(ConvertTo-JsonText "$Base/creatures/"),`n" +
    "  `"generated`": $(ConvertTo-JsonText $generated),`n" +
    "  `"abilities`": $(ConvertTo-JsonText $Abilities),`n" +
    "  `"aniimo`": [`n" +
    ((@($all | ForEach-Object { '    ' + (ConvertTo-JsonText $_) })) -join ",`n") +
    "`n  ]`n}`n"
}
# Unchanged = the file we'd write (keeping its old date) is byte-for-byte what's there
#   (read the date as raw text: PowerShell 7's ConvertFrom-Json turns it into a DateTime)
$oldText = if (Test-Path $OutFile) { [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($OutFile)) } else { '' }
$oldDate = [regex]::Match($oldText, '"generated":\s*"([^"]*)"').Groups[1].Value
if ($oldText -and (Format-DataFile $oldDate) -eq $oldText.Replace("`r`n", "`n")) {
    Write-Host "No changes ($($all.Count) entries)."
    exit 0
}
$json = Format-DataFile (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutFile), $json, (New-Object System.Text.UTF8Encoding $false))

$summary | ForEach-Object { Write-Host $_ }
if ($SummaryFile) {
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($SummaryFile), ($summary -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
}
Write-Host "Wrote $($all.Count) entries to $OutFile"

# Rebuild the ability pages, sitemap and ability links from the new data
& (Join-Path $PSScriptRoot 'build-pages.ps1') -SiteDir (Split-Path (Split-Path $OutFile -Parent) -Parent)