<#
.SYNOPSIS
    Draws the PitCrew icon and writes assets\pitcrew.ico and assets\pitcrew.png.

.DESCRIPTION
    The icon is drawn from code (WPF geometry), so it can be changed and rebuilt without any image
    editor. Small sizes use a bolder wrench so it still reads at 16 px. Frames up to 64 px are
    stored as 32-bit bitmaps (with the AND mask Windows expects); the 256 px frame is PNG.
    Must run in an STA process:
    powershell -STA -File tools\Build-Icon.ps1 [-Preview sheet.png]
#>
param(
    # Optional contact sheet with every size on a light and a dark background, enlarged
    [string]$Preview
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$root = Split-Path $PSScriptRoot -Parent
$assets = Join-Path $root 'assets'

$IconSizes = 16, 20, 24, 32, 40, 48, 64, 256

function New-PcBrush([string]$Hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    $b
}

function New-PcWrenchGeometry([double]$Length, [double]$HeadRadius, [double]$Handle, [double]$Slot, [double]$Hole) {
    # An open-end wrench drawn upright in a 256 x 256 box, then turned 45 degrees
    $cx = 128.0
    $top = 128.0 - $Length / 2
    $headCy = $top + $HeadRadius
    $head = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($cx, $headCy)), $HeadRadius, $HeadRadius)
    $handleRect = New-Object Windows.Rect(($cx - $Handle / 2), $headCy, $Handle, ($top + $Length - $headCy))
    $body = [Windows.Media.Geometry]::Combine($head, (New-Object Windows.Media.RectangleGeometry($handleRect, ($Handle / 2), ($Handle / 2))), 'Union', $null)
    $slotRect = New-Object Windows.Rect(($cx - $Slot / 2), ($top - 20), $Slot, ($headCy - $top + 20 + $Slot * 0.15))
    $body = [Windows.Media.Geometry]::Combine($body, (New-Object Windows.Media.RectangleGeometry($slotRect)), 'Exclude', $null)
    if ($Hole -gt 0) {
        $center = New-Object Windows.Point($cx, ($top + $Length - $Handle / 2 - 4))
        $body = [Windows.Media.Geometry]::Combine($body, (New-Object Windows.Media.EllipseGeometry($center, $Hole, $Hole)), 'Exclude', $null)
    }
    $body.Transform = New-Object Windows.Media.RotateTransform(45, 128, 128)
    $body
}

function Add-PcIconDrawing($Dc, [int]$Size) {
    $small = $Size -lt 40
    $margin = if ($small) { 0 } else { 10 }
    $tile = New-Object Windows.Rect($margin, $margin, (256 - 2 * $margin), (256 - 2 * $margin))
    $radius = 52

    # Dark tile, slightly lighter at the top
    $gradient = New-Object Windows.Media.LinearGradientBrush(
        [Windows.Media.ColorConverter]::ConvertFromString('#23262E'),
        [Windows.Media.ColorConverter]::ConvertFromString('#121418'), 90)
    $gradient.Freeze()
    $border = $null
    if ($Size -ge 24) {
        # A faint edge keeps the tile visible on a dark taskbar
        $border = New-Object Windows.Media.Pen((New-PcBrush '#3A3F49'), ([Math]::Max(256.0 / $Size, 3)))
        $border.Freeze()
    }
    $Dc.DrawRoundedRectangle($gradient, $border, $tile, $radius, $radius)

    # Racing stripe along the wrench, clipped to the tile
    $stripe = New-Object Windows.Media.RectangleGeometry((New-Object Windows.Rect(-40, 150, 340, 34)))
    $stripe.Transform = New-Object Windows.Media.RotateTransform(-45, 128, 128)
    $Dc.PushClip((New-Object Windows.Media.RectangleGeometry($tile, $radius, $radius)))
    $Dc.DrawGeometry((New-PcBrush '#E10600'), $null, $stripe)
    $Dc.Pop()

    if ($small) { $wrench = New-PcWrenchGeometry 214 56 54 46 0 }
    else { $wrench = New-PcWrenchGeometry 206 50 42 38 11 }
    $Dc.DrawGeometry((New-PcBrush '#FFFFFF'), $null, $wrench)
}

function New-PcIconBitmap([int]$Size) {
    $visual = New-Object Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    $dc.PushTransform((New-Object Windows.Media.ScaleTransform(($Size / 256.0), ($Size / 256.0))))
    Add-PcIconDrawing $dc $Size
    $dc.Pop()
    $dc.Close()
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $bitmap.Freeze()
    $bitmap
}

function ConvertTo-PcPngBytes($Bitmap) {
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = New-Object IO.MemoryStream
    $encoder.Save($stream)
    # The comma keeps the array whole instead of sending it down the pipeline byte by byte
    , $stream.ToArray()
}

function ConvertTo-PcIconDib($Bitmap) {
    # BITMAPINFOHEADER + bottom-up BGRA (straight alpha) + 1-bit AND mask. The header's height is
    # doubled because it covers both the color image and the mask.
    $size = $Bitmap.PixelWidth
    $straight = New-Object Windows.Media.Imaging.FormatConvertedBitmap($Bitmap, [Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $stride = $size * 4
    $pixels = New-Object byte[] ($stride * $size)
    $straight.CopyPixels($pixels, $stride, 0)
    $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)

    $stream = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($stream)
    $w.Write([int]40); $w.Write([int]$size); $w.Write([int]($size * 2))
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]0)
    $w.Write([int]($stride * $size + $maskStride * $size))
    $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    for ($y = $size - 1; $y -ge 0; $y--) { $w.Write($pixels, $y * $stride, $stride) }
    for ($y = $size - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $size; $x++) {
            if ($pixels[$y * $stride + $x * 4 + 3] -eq 0) { $row[$x -shr 3] = [byte]($row[$x -shr 3] -bor (0x80 -shr ($x -band 7))) }
        }
        $w.Write($row)
    }
    $w.Flush()
    # The comma keeps the array whole instead of sending it down the pipeline byte by byte
    , $stream.ToArray()
}

function Write-PcIconFile([string]$Path, $Frames) {
    $stream = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($stream)
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$Frames.Count)
    $offset = 6 + 16 * $Frames.Count
    foreach ($f in $Frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$f.Bytes.Length); $w.Write([int]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $Frames) { $w.Write($f.Bytes) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $stream.ToArray())
}

New-Item -ItemType Directory -Force -Path $assets | Out-Null
$frames = foreach ($size in $IconSizes) {
    $bitmap = New-PcIconBitmap $size
    $bytes = if ($size -ge 256) { ConvertTo-PcPngBytes $bitmap } else { ConvertTo-PcIconDib $bitmap }
    [pscustomobject]@{ Size = $size; Bytes = [byte[]]$bytes }
}
Write-PcIconFile (Join-Path $assets 'pitcrew.ico') @($frames)
[IO.File]::WriteAllBytes((Join-Path $assets 'pitcrew.png'), (ConvertTo-PcPngBytes (New-PcIconBitmap 256)))

if ($Preview) {
    # Decode the written file (not the in-memory bitmaps) so a broken frame shows up here
    $decoder = New-Object Windows.Media.Imaging.IconBitmapDecoder((New-Object Uri (Join-Path $assets 'pitcrew.ico')),
        [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $sheet = New-Object Windows.Media.DrawingVisual
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($sheet, 'NearestNeighbor')
    $dc = $sheet.RenderOpen()
    $width = 2 * 950; $height = 300
    $dc.DrawRectangle((New-PcBrush '#FFFFFF'), $null, (New-Object Windows.Rect(0, 0, $width, $height)))
    $x0 = 0
    foreach ($bg in '#F3F3F3', '#202020') {
        $dc.DrawRectangle((New-PcBrush $bg), $null, (New-Object Windows.Rect($x0, 0, 946, $height)))
        $x = $x0 + 10
        foreach ($frame in $decoder.Frames) {
            $s = $frame.PixelWidth
            if ($s -ge 256) { $dc.DrawImage($frame, (New-Object Windows.Rect($x, 10, 256, 256))); $x += 266; continue }
            $zoom = [int][Math]::Max(1, [Math]::Floor(96 / $s))
            $dc.DrawImage($frame, (New-Object Windows.Rect($x, 10, ($s * $zoom), ($s * $zoom))))
            $dc.DrawImage($frame, (New-Object Windows.Rect($x, (20 + $s * $zoom), $s, $s)))
            $x += [Math]::Max(60, $s * $zoom + 8)
        }
        $x0 += 950
    }
    $dc.Close()
    $png = New-Object Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $png.Render($sheet)
    [IO.File]::WriteAllBytes($Preview, (ConvertTo-PcPngBytes $png))
}
'{0} frames: {1}' -f $frames.Count, (($frames | ForEach-Object { "$($_.Size)px" }) -join ', ')
