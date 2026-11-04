# Interface texts live in locales/<lang>.json (flat key -> text). English is the base: a key
# missing from another language falls back to English, and a key missing everywhere shows itself.
# Tweak and app texts are stored next to the tweak itself as { "en": "...", "pt-BR": "..." }.

function Get-PcAvailableLanguages {
    Get-ChildItem -LiteralPath (Join-Path $Pc.Root 'locales') -Filter '*.json' | ForEach-Object {
        $meta = (Read-PcJson $_.FullName).'_meta'
        [pscustomobject]@{ Code = $_.BaseName; Name = $meta.name }
    } | Sort-Object Name
}

function Get-PcDefaultLanguage {
    $culture = (Get-UICulture).Name
    $available = @(Get-ChildItem -LiteralPath (Join-Path $Pc.Root 'locales') -Filter '*.json' | ForEach-Object BaseName)
    if ($available -contains $culture) { return $culture }
    # pt-PT -> pt-BR, es-MX -> es, zh-Hans-CN -> zh-CN...
    $prefix = $culture.Split('-')[0]
    $match = $available | Where-Object { $_ -eq $prefix -or $_.StartsWith("$prefix-") } | Select-Object -First 1
    if ($match) { return $match }
    return 'en'
}

function Import-PcLocale([string]$Language) {
    $dir = Join-Path $Pc.Root 'locales'
    $texts = @{}
    foreach ($code in @('en', $Language) | Select-Object -Unique) {
        $file = Join-Path $dir "$code.json"
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($p in (Read-PcJson $file).PSObject.Properties) {
            if ($p.Name -ne '_meta') { $texts[$p.Name] = $p.Value }
        }
    }
    $Pc.Language = $Language
    $Pc.Texts = $texts
}

function Get-PcText {
    param([Parameter(Mandatory)][string]$Key, [object[]]$FormatArgs)
    $text = $Pc.Texts[$Key]
    if (-not $text) { return $Key }
    # ContainsKey, not a truth test: a single 0 is a real argument
    if ($PSBoundParameters.ContainsKey('FormatArgs')) { return $text -f $FormatArgs }
    return $text
}

function Resolve-PcLocalized($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $text = $Value.($Pc.Language)
    if (-not $text) { $text = $Value.en }
    return [string]$text
}
