[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Source,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'TmuxHub.Windows\Assets')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$sourcePath = [System.IO.Path]::GetFullPath($Source)
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Source image not found: $sourcePath"
}

[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$pngPath = Join-Path $outputPath 'TmuxHub.Windows.png'
$icoPath = Join-Path $outputPath 'TmuxHub.Windows.ico'

function New-ScaledBitmap {
    param(
        [Parameter(Mandatory)] [System.Drawing.Image]$Image,
        [Parameter(Mandatory)] [int]$Size
    )

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bitmap.SetResolution(96, 96)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Image, 0, 0, $Size, $Size)
    }
    finally {
        $graphics.Dispose()
    }
    return $bitmap
}

$sourceBitmap = [System.Drawing.Bitmap]::FromFile($sourcePath)
$croppedBitmap = $null
$masterBitmap = $null
try {
    $left = $sourceBitmap.Width
    $top = $sourceBitmap.Height
    $right = -1
    $bottom = -1
    for ($y = 0; $y -lt $sourceBitmap.Height; $y++) {
        for ($x = 0; $x -lt $sourceBitmap.Width; $x++) {
            if ($sourceBitmap.GetPixel($x, $y).A -gt 2) {
                if ($x -lt $left) { $left = $x }
                if ($x -gt $right) { $right = $x }
                if ($y -lt $top) { $top = $y }
                if ($y -gt $bottom) { $bottom = $y }
            }
        }
    }

    if ($right -lt $left -or $bottom -lt $top) {
        throw 'The source image contains no visible pixels.'
    }

    $contentWidth = $right - $left + 1
    $contentHeight = $bottom - $top + 1
    $cropSize = [int][Math]::Ceiling([Math]::Max($contentWidth, $contentHeight) * 1.10)
    $cropSize = [Math]::Min($cropSize, [Math]::Min($sourceBitmap.Width, $sourceBitmap.Height))
    $centerX = ($left + $right) / 2.0
    $centerY = ($top + $bottom) / 2.0
    $cropX = [int][Math]::Round($centerX - ($cropSize / 2.0))
    $cropY = [int][Math]::Round($centerY - ($cropSize / 2.0))
    $cropX = [Math]::Max(0, [Math]::Min($cropX, $sourceBitmap.Width - $cropSize))
    $cropY = [Math]::Max(0, [Math]::Min($cropY, $sourceBitmap.Height - $cropSize))

    $cropRectangle = New-Object System.Drawing.Rectangle $cropX, $cropY, $cropSize, $cropSize
    $croppedBitmap = $sourceBitmap.Clone($cropRectangle, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $masterBitmap = New-ScaledBitmap -Image $croppedBitmap -Size 1024
    $masterBitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

    $sizes = @(256, 128, 96, 64, 48, 40, 32, 24, 20, 16)
    $frames = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $sizes) {
        $frameBitmap = New-ScaledBitmap -Image $masterBitmap -Size $size
        $stream = New-Object System.IO.MemoryStream
        try {
            $frameBitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $frames.Add($stream.ToArray())
        }
        finally {
            $stream.Dispose()
            $frameBitmap.Dispose()
        }
    }

    $fileStream = [System.IO.File]::Open($icoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter $fileStream
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $size = $sizes[$index]
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $frames[$index].Length
        }
        foreach ($frame in $frames) {
            $writer.Write($frame)
        }
    }
    finally {
        $writer.Dispose()
        $fileStream.Dispose()
    }
}
finally {
    if ($null -ne $masterBitmap) { $masterBitmap.Dispose() }
    if ($null -ne $croppedBitmap) { $croppedBitmap.Dispose() }
    $sourceBitmap.Dispose()
}

Write-Host "Created $pngPath"
Write-Host "Created $icoPath"
