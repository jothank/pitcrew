# New-version notice. PitCrew asks once, the first time the window opens, whether it may check
# (answer kept in the preferences, changeable on the About page). With yes, it reads GitHub's public
# list of releases when the window opens, at most once a day, and shows a link to the newer
# release's page. Nothing about the person or the PC is sent, and nothing is downloaded or installed.

$script:PcReleasesApi = 'https://api.github.com/repos/jothank/pitcrew/releases?per_page=20'

function Get-PcReleaseList {
    # The only request: runs in a background runspace (Window.ps1 sends this body there), so it
    # takes its URL as a parameter and uses nothing else from PitCrew. Returns the JSON text.
    param([string]$Url)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    # Windows PowerShell can still default to TLS 1.0, which GitHub refuses. SystemDefault (0)
    # already offers TLS 1.2, so it is left alone.
    $protocols = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$protocols -ne 0 -and -not ($protocols -band [Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
    }
    (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent 'PitCrew' -TimeoutSec 15 -Headers @{ Accept = 'application/vnd.github+json' }).Content
}

function ConvertTo-PcVersion([string]$Text) {
    # "v0.1.2-beta" or "0.1.2" -> numbers and prerelease labels; $null for anything else. Whatever
    # passes this goes into a link, so only ASCII digits, letters, dots and hyphens get through.
    if ($Text -cnotmatch '\Av?([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})(?:-([0-9A-Za-z]{1,20}(?:\.[0-9A-Za-z]{1,20}){0,4}))?\z') { return $null }
    [pscustomobject]@{
        Tag     = $Text
        Text    = $Text.TrimStart('v')
        Numbers = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        Pre     = @(if ($Matches[4]) { $Matches[4].Split('.') })
    }
}

function Compare-PcVersion($A, $B) {
    # Semantic Versioning order: -1, 0 or 1
    for ($i = 0; $i -lt 3; $i++) {
        if ($A.Numbers[$i] -ne $B.Numbers[$i]) { return [Math]::Sign($A.Numbers[$i] - $B.Numbers[$i]) }
    }
    # A release ranks above its own betas: 0.2.0 > 0.2.0-beta
    if ($A.Pre.Count -eq 0 -or $B.Pre.Count -eq 0) { return [Math]::Sign($B.Pre.Count - $A.Pre.Count) }
    for ($i = 0; $i -lt [Math]::Min($A.Pre.Count, $B.Pre.Count); $i++) {
        $x = $A.Pre[$i]; $y = $B.Pre[$i]
        $xNumber = $x -match '\A[0-9]+\z'; $yNumber = $y -match '\A[0-9]+\z'
        if ($xNumber -and $yNumber) {
            # Compared as numbers of any length: beta.10 > beta.9
            $x = $x.TrimStart('0'); $y = $y.TrimStart('0')
            $c = if ($x.Length -ne $y.Length) { $x.Length - $y.Length } else { [string]::CompareOrdinal($x, $y) }
        } elseif ($xNumber) { $c = -1 } elseif ($yNumber) { $c = 1 }
        else { $c = [string]::CompareOrdinal($x, $y) }
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return [Math]::Sign($A.Pre.Count - $B.Pre.Count)
}

function Select-PcNewerRelease {
    # The newest tag above the running version, as { Version, Tag, Url }, or $null. Tags that are
    # not plain versions are skipped. The link is built here, never taken from the answer.
    param([string[]]$Tags, [string]$Current = $script:PcVersion)
    $mine = ConvertTo-PcVersion $Current
    if (-not $mine) { return $null }
    $best = $null
    foreach ($tag in $Tags) {
        $v = ConvertTo-PcVersion $tag
        if (-not $v) { continue }
        # Someone on a release is only told about releases; someone on a beta also about betas
        if ($mine.Pre.Count -eq 0 -and $v.Pre.Count -gt 0) { continue }
        if (-not $best -or (Compare-PcVersion $v $best) -gt 0) { $best = $v }
    }
    if (-not $best -or (Compare-PcVersion $best $mine) -le 0) { return $null }
    [pscustomobject]@{
        Version = $best.Text
        Tag     = $best.Tag
        Url     = '{0}/releases/tag/{1}' -f $script:PcLinks.Repository, $best.Tag
    }
}

function Find-PcNewerRelease {
    # From the JSON GitHub returns: drafts are skipped, and so is anything GitHub marks as a
    # prerelease when the running version is a release. Throws when the text is not that list (an
    # empty answer from a proxy, an error object), so it is never taken for "up to date".
    param([string]$Json, [string]$Current = $script:PcVersion)
    # Assigned first: Windows PowerShell 5.1 returns a top-level JSON array as one object
    $releases = ConvertFrom-Json -InputObject $Json
    if ($releases -isnot [array]) { throw 'GitHub did not answer with a list of releases' }
    if ($releases.Count -gt 0 -and -not @($releases | Where-Object { $_.tag_name -is [string] })) {
        throw 'GitHub answered with a list that has no releases in it'
    }
    $mine = ConvertTo-PcVersion $Current
    $stable = $mine -and $mine.Pre.Count -eq 0
    $tags = @(foreach ($r in $releases) {
        if ($r.tag_name -isnot [string] -or $r.draft -eq $true) { continue }
        if ($stable -and $r.prerelease -eq $true) { continue }
        $r.tag_name
    })
    Select-PcNewerRelease -Tags $tags -Current $Current
}
