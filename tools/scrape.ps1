# Builds data/aniimo.json from metabot.gg creature pages, then applies data/overrides.json.
#
#   powershell -ExecutionPolicy Bypass -File tools\scrape.ps1           # full refresh
#   powershell -ExecutionPolicy Bypass -File tools\scrape.ps1 -Only tromber,glacy
#
# The file is only rewritten when the data actually changed. The run aborts (exit 1)
# without writing anything if the scrape looks broken: failed pages, many entries
# vanishing, entries with nothing parsed, or an ability name it doesn't recognise.
# -Force skips those checks. -SummaryFile writes a Markdown summary of the changes.
param(
    [int]$DelayMs = 600,
    [string[]]$Only,   # optional creature slugs to fetch instead of the full index
    [string]$OutFile = (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'data') 'aniimo.json'),
    [string]$OverridesFile = (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'data') 'overrides.json'),
    [string]$SummaryFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Resolve relative paths against the current PowerShell location (not .NET's working directory)
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$OverridesFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OverridesFile)
if ($SummaryFile) { $SummaryFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SummaryFile) }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Base = 'https://metabot.gg'
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
    $script:UnknownAbilities += $n
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
    # Bosses can't be owned by players. Other cases (NPC-only entries, duplicate pages)
    # are listed in data/overrides.json. ("No wild spawn" alone isn't enough: e.g.
    # Besauce comes from a fragment exchange.)
    $unobtainable = $slug -match 'boss'

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
    }
}

function Format-Abilities($e) {
    (@($e.abilities.Keys | ForEach-Object { "$_ $($e.abilities[$_])" }) -join ', ')
}

# ---------- main ----------

$script:UnknownAbilities = @()

if ($Only) { $paths = $Only -split ',' | ForEach-Object { "/en/aniimo/creatures/$($_.Trim())" } } else {
    Write-Host 'Fetching creature index...'
    $index = Get-Html "$Base/en/aniimo/creatures"
    # The grid lazy-loads, so also read the full list from the page's structured data
    $paths = @([regex]::Matches($index, '(?:href="|metabot\.gg)(/en/aniimo/creatures/[a-z0-9\-]+)') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
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
$all = @($all | Sort-Object { $_.name }, { [bool]$_.form }, { $_.form }, { $_.id })

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
        foreach ($k in 'name', 'form', 'prismana', 'unobtainable', 'page') { if ("$($o[$k])" -ne "$($e[$k])") { $what += "$k '$($o[$k])' -> '$($e[$k])'" } }
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
    "  `"source`": $(ConvertTo-JsonText "$Base/en/aniimo/creatures"),`n" +
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