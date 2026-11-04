<#
.SYNOPSIS
    Draws assets\pix-qr.png (the donation QR code on the About page and in the README) from the
    Pix data in src\Core\Context.ps1, and writes the "copia e cola" text next to it.

.DESCRIPTION
    Uses tools\QrCode.cs, compiled on the fly: nothing is downloaded. Run it again after changing
    the Pix key, name or city. A test checks that assets\pix-qr.txt matches the current data.
    powershell -File tools\Build-PixQr.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -Language en
Add-Type -AssemblyName System.Drawing
if (-not ('PitCrew.QrCode' -as [type])) { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'QrCode.cs'))) }

$payload = Get-PcPixPayload
$qr = [PitCrew.QrCode]::Encode([Text.Encoding]::UTF8.GetBytes($payload))

# 4 light modules of quiet zone around it, as scanners expect; black on white in every theme
$scale = 8
$quiet = 4
$pixels = ($qr.Size + 2 * $quiet) * $scale
$bitmap = New-Object System.Drawing.Bitmap $pixels, $pixels
$g = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $g.Clear([System.Drawing.Color]::White)
    for ($y = 0; $y -lt $qr.Size; $y++) {
        for ($x = 0; $x -lt $qr.Size; $x++) {
            if ($qr.IsDark($x, $y)) { $g.FillRectangle([System.Drawing.Brushes]::Black, ($x + $quiet) * $scale, ($y + $quiet) * $scale, $scale, $scale) }
        }
    }
} finally { $g.Dispose() }
$png = Join-Path $root 'assets\pix-qr.png'
$bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
[IO.File]::WriteAllText((Join-Path $root 'assets\pix-qr.txt'), $payload + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Built $png (QR version $($qr.Version), mask $($qr.Mask), $pixels px)"
Write-Host $payload
