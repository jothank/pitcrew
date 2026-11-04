<#
.SYNOPSIS
    Builds PitCrew.exe and the release zip in dist\. Publishes nothing.

.DESCRIPTION
    1. Runs tests\Run-Tests.ps1 (skip with -SkipTests).
    2. Compiles tools\launcher\PitCrew.cs with the C# compiler that ships with Windows
       (.NET Framework 4), with the icon from assets\ and the version from src\Core\Context.ps1.
    3. Builds dist\PitCrew-<version>.zip with git archive from the last commit, so a release always
       matches a commit and logs or local tool state can't end up in it. It refuses to run with
       uncommitted changes; -Dev builds dist\PitCrew-<version>-dev.zip from them instead (for
       testing only), using a throwaway index so git's own index is not touched.
    4. Puts everything in a PitCrew\ folder inside the zip (so "Extract here" never drops
       PitCrew.exe straight into Downloads), adds PitCrew.exe, checks every entry against a list of
       what may ship, and writes the SHA-256 next to the zip.

    -ExeFile puts an already built PitCrew.exe in the zip instead of compiling one: the copy that came
    back from code signing (.github\workflows\build.yml). With -RequireSignature the zip is only
    built if that exe has a valid, timestamped signature and this version.

    powershell -File tools\Build-Release.ps1 [-Dev] [-OutDir dist] [-SkipTests]
    powershell -File tools\Build-Release.ps1 -ExeOnly -OutDir <folder>   (only PitCrew.exe)
    powershell -File tools\Build-Release.ps1 -ExeFile <signed PitCrew.exe> -RequireSignature
#>
param(
    [string]$OutDir,
    [switch]$Dev,
    [switch]$SkipTests,
    [switch]$ExeOnly,
    [string]$ExeFile,
    [switch]$RequireSignature
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

# Everything a release may contain at its top level; anything else stops the build
$script:ReleaseTop = 'PitCrew.exe', 'PitCrew.ps1', 'PitCrew.bat', 'README.md', 'README.pt-BR.md', 'LICENSE',
    'CHANGELOG.md', 'SECURITY.md', 'assets', 'data', 'docs', 'locales', 'src', 'tests', 'tools', 'tweaks'

function Get-PcBuildVersion {
    $text = [IO.File]::ReadAllText((Join-Path $root 'src\Core\Context.ps1'))
    $m = [regex]::Match($text, "\`$script:PcVersion\s*=\s*'(?<full>(?<numeric>\d+\.\d+\.\d+)(-[0-9A-Za-z.]+)?)'")
    if (-not $m.Success) { throw 'No $script:PcVersion in src\Core\Context.ps1' }
    [pscustomobject]@{ Full = $m.Groups['full'].Value; Numeric = $m.Groups['numeric'].Value }
}

function Invoke-PcGit {
    # git prints line-ending notes on stderr; only the exit code decides. --no-optional-locks keeps
    # read-only commands like status from rewriting git's index.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -C $root --no-optional-locks -c core.safecrlf=false @args 2>&1 } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed:`n$($out -join "`n")" }
    @($out | Where-Object { $_ -is [string] })
}

function Get-PcGitLine {
    # The last line a git command prints. @() keeps a single line a list: indexing a lone string
    # would return one character.
    $lines = @(Invoke-PcGit @args)
    $lines[-1].Trim()
}

function Build-PcLauncher([string]$Destination, $Version) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('pitcrew-build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $versionFile = Join-Path $work 'Version.cs'
        [IO.File]::WriteAllLines($versionFile, [string[]]@(
            ('[assembly: System.Reflection.AssemblyVersion("{0}.0")]' -f $Version.Numeric)
            ('[assembly: System.Reflection.AssemblyFileVersion("{0}.0")]' -f $Version.Numeric)
            ('[assembly: System.Reflection.AssemblyInformationalVersion("{0}")]' -f $Version.Full)))
        # anycpu without 32-bit preference: runs 64-bit on 64-bit Windows, so it starts 64-bit PowerShell
        $out = & $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
            "/win32icon:$(Join-Path $root 'assets\pitcrew.ico')" `
            "/win32manifest:$(Join-Path $root 'tools\launcher\PitCrew.exe.manifest')" `
            "/out:$Destination" (Join-Path $root 'tools\launcher\PitCrew.cs') $versionFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "csc failed:`n$($out -join "`n")" }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-PcWorkingTree {
    # The tree a commit of the folder would have right now, built in a throwaway index
    $index = Join-Path ([IO.Path]::GetTempPath()) ('pitcrew-index-' + [guid]::NewGuid().ToString('N'))
    $saved = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $index
        Invoke-PcGit read-tree HEAD | Out-Null
        Invoke-PcGit add -A | Out-Null
        Get-PcGitLine write-tree
    } finally {
        if ($saved) { $env:GIT_INDEX_FILE = $saved } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue
    }
}

function Test-PcReleaseEntries([string[]]$Entries) {
    # Returns what's wrong with the zip's entry list; empty means it can ship
    $problems = @()
    $files = @($Entries | Where-Object { $_ -notmatch '/$' })
    foreach ($group in ($files | Group-Object { $_.ToLowerInvariant() } | Where-Object Count -gt 1)) { $problems += "twice: $($group.Name)" }
    foreach ($e in $files) {
        if ($e -notmatch '^PitCrew/(?<top>[^/]+)') { $problems += "outside PitCrew/: $e"; continue }
        if ($script:ReleaseTop -notcontains $Matches['top']) { $problems += "not allowed at the top: $e"; continue }
        # Binaries, keys and archives never ship by accident; the only exe is the launcher
        if ($e -ne 'PitCrew/PitCrew.exe' -and $e -match '\.(exe|dll|sys|msi|pfx|p12|snk|key|pem|zip|7z|config)$|/\.env$') { $problems += "not allowed: $e" }
    }
    foreach ($required in 'PitCrew.exe', 'PitCrew.ps1', 'PitCrew.bat', 'LICENSE', 'README.md', 'src/Load.ps1', 'src/UI/Window.xaml',
        'assets/pitcrew.ico', 'assets/pitcrew.png', 'locales/en.json', 'tweaks/privacy.json', 'data/apps.json') {
        if ($files -notcontains "PitCrew/$required") { $problems += "missing: $required" }
    }
    $problems
}

function Test-PcGivenExe([string]$Path, $Version, [switch]$Signed) {
    # Returns what's wrong with an exe built elsewhere (the signed copy); empty means it can ship
    $problems = @()
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($info.ProductName -ne 'PitCrew') { $problems += "product name '$($info.ProductName)', expected 'PitCrew'" }
    if ($info.ProductVersion -ne $Version.Full) { $problems += "version $($info.ProductVersion), expected $($Version.Full)" }
    if ($Signed) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid') { $problems += "signature: $($signature.Status) ($($signature.StatusMessage))" }
        elseif (-not $signature.TimeStamperCertificate) { $problems += 'the signature has no timestamp, so it would stop being valid when the certificate expires' }
    }
    $problems
}

$version = Get-PcBuildVersion

if ($ExeFile) {
    $ExeFile = (Resolve-Path -LiteralPath $ExeFile).ProviderPath
    $problems = @(Test-PcGivenExe $ExeFile $version -Signed:$RequireSignature)
    if ($problems) { throw "PitCrew.exe can't ship:`n$($problems -join "`n")" }
    if ($RequireSignature) { Write-Host "PitCrew.exe signed by: $((Get-AuthenticodeSignature -LiteralPath $ExeFile).SignerCertificate.Subject)" }
} elseif ($RequireSignature) { throw '-RequireSignature needs -ExeFile: the signed PitCrew.exe' }

if ($ExeOnly) {
    $exe = Join-Path $OutDir 'PitCrew.exe'
    Build-PcLauncher $exe $version
    Write-Host "Built $exe ($($version.Full))"
    return
}

$dirty = @(Invoke-PcGit status --porcelain).Count -gt 0
if ($dirty -and -not $Dev) { throw 'There are uncommitted changes. Commit them first, or use -Dev for a test build.' }

if (-not $SkipTests) {
    Write-Host 'Running tests...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Tests failed ($LASTEXITCODE). Nothing was built." }
}

$name = if ($Dev) { "PitCrew-$($version.Full)-dev" } else { "PitCrew-$($version.Full)" }
$tree = if ($Dev) { Get-PcWorkingTree } else { Get-PcGitLine rev-parse 'HEAD^{tree}' }
$commit = Get-PcGitLine rev-parse --short HEAD
$zipPath = Join-Path $OutDir "$name.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ('pitcrew-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $exe = Join-Path $work 'PitCrew.exe'
    if ($ExeFile) { Copy-Item -LiteralPath $ExeFile -Destination $exe } else { Build-PcLauncher $exe $version }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Invoke-PcGit archive --format=zip --prefix=PitCrew/ -o $zipPath $tree | Out-Null

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        if ($zip.GetEntry('PitCrew/PitCrew.exe')) { throw 'The tree already has a PitCrew.exe' }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $exe, 'PitCrew/PitCrew.exe', [IO.Compression.CompressionLevel]::Optimal)
    } finally { $zip.Dispose() }
} catch {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    throw
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try { $entries = @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }
$problems = @(Test-PcReleaseEntries $entries)
if ($problems) {
    Remove-Item -LiteralPath $zipPath -Force
    throw "The zip was not kept:`n$($problems -join "`n")"
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zipPath.sha256", "$hash  $name.zip`n", (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Built $zipPath ($([Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)) KB, $(@($entries | Where-Object { $_ -notmatch '/$' }).Count) files)"
Write-Host "SHA-256 $hash"
if ($Dev) { Write-Host "From uncommitted changes on top of $commit (tree $tree): for testing, not for publishing." -ForegroundColor Yellow }
else { Write-Host "From commit $commit" }
