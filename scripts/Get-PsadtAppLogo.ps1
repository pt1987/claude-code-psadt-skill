<#
    Get-PsadtAppLogo.ps1 - resolve an app logo from the logo-source catalog and produce a verified PNG.

    Acquiring one logo cost about as long as the entire Phase 6 gate (Thunderbird, 2026-09-21: roughly
    four minutes against 3.8 for the gate). None of that work changes between versions: the search, the
    two traps and the visual check are the same every time, so they belong in a catalog and not in a run.

    What it will NOT do, on purpose:

      * It never constructs a source URL it was not given. A guessed slug that 404s costs a minute; a
        guessed slug that RESOLVES gives you a confident wrong logo, and nothing downstream looks at the
        picture. An unknown product returns a miss that names where to look, and a human adds the entry
        after seeing the image.
      * It never accepts its own output silently. Size, squareness and REAL corner alpha are measured and
        returned; a caller that wants to ship the file still has to look at it (App. J).

    .PARAMETER ProductName
        The product as the binary reports it - Get-PsadtInstallerEngine.ps1 .ProductName, which is the
        same key the verified-switch store falls back on.

    .PARAMETER Path
        An installer to read the product name out of instead of passing -ProductName.

    .OUTPUTS
        PSCustomObject: ProductName, Found, Source, Url, Fetch, PostProcess, OutFile, Width, Height,
        Transparent, CornerAlpha, Note, Warnings, Misses.
#>
[CmdletBinding()]
param(
    [string]$ProductName,

    [string]$Path,

    # Where the PNG is written. Required only when an entry is actually found.
    [string]$OutFile,

    # Rendered edge length for a vector source. App. J wants >= 512; 1024 is a sensible tile.
    [ValidateRange(256, 4096)][int]$Size = 1024,

    # The catalog to read. Exists so a test can point at a fixture without touching what ships, and so a
    # team can keep one shared file on a network share.
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'

$result = [pscustomobject]@{
    ProductName = $ProductName
    Found       = $false
    Source      = $null
    Url         = $null
    Fetch       = $null
    PostProcess = $null
    OutFile     = $null
    Width       = 0
    Height      = 0
    Transparent = $false
    CornerAlpha = @()
    Note        = $null
    Warnings    = @()
    Misses      = @()
}

function Add-Miss([string]$Reason) { $result.Misses += $Reason }
function Add-Warn([string]$Reason) { $result.Warnings += $Reason }

function Invoke-BorderKey {
    <#
        Flood transparency in from the image border and stop where the artwork starts.

        NOT a global white key. The Thunderbird mark carries a white envelope in its middle, and keying
        every white pixel erases it - the background is only the white CONNECTED TO THE EDGE. Border
        pixels get a partial alpha from how near-white they were, which is what keeps the outline from
        going jagged.

        Done in PowerShell over the raw buffer rather than in a compiled helper: Add-Type cannot bind
        against System.Drawing.Bitmap in this .NET build without dragging System.Private.Windows.* in by
        hand, and at ~1 minute for a 1280px image this is fast enough for something that runs once per
        product, ever.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$Tolerance = 12)

    Add-Type -AssemblyName System.Drawing.Common
    $src = [System.Drawing.Bitmap]::FromFile($Path)
    $w = $src.Width; $h = $src.Height
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose(); $src.Dispose()

    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $bd.Stride
    $buf = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)

    $seen = New-Object bool[] ($w * $h)
    $stack = New-Object System.Collections.Generic.Stack[int]
    for ($x = 0; $x -lt $w; $x++) { $stack.Push($x); $stack.Push(($h - 1) * $w + $x) }
    for ($y = 0; $y -lt $h; $y++) { $stack.Push($y * $w); $stack.Push($y * $w + $w - 1) }

    $cleared = 0
    while ($stack.Count -gt 0) {
        $idx = $stack.Pop()
        if ($seen[$idx]) { continue }
        $x = $idx % $w
        $y = [int](($idx - $x) / $w)
        $o = $y * $stride + $x * 4
        $d = 255 - $buf[$o]
        $d2 = 255 - $buf[$o + 1]
        $d3 = 255 - $buf[$o + 2]
        if ($d2 -gt $d) { $d = $d2 }
        if ($d3 -gt $d) { $d = $d3 }
        if ($d -gt $Tolerance) { continue }
        $seen[$idx] = $true
        $buf[$o + 3] = [byte]([int]($d * 255 / $Tolerance))
        $cleared++
        if ($x -gt 0)      { $i = $idx - 1;  if (-not $seen[$i]) { $stack.Push($i) } }
        if ($x -lt $w - 1) { $i = $idx + 1;  if (-not $seen[$i]) { $stack.Push($i) } }
        if ($y -gt 0)      { $i = $idx - $w; if (-not $seen[$i]) { $stack.Push($i) } }
        if ($y -lt $h - 1) { $i = $idx + $w; if (-not $seen[$i]) { $stack.Push($i) } }
    }

    [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $bd.Scan0, $buf.Length)
    $bmp.UnlockBits($bd)
    $tmpOut = $Path + '.tmp'
    $bmp.Save($tmpOut, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Move-Item -LiteralPath $tmpOut -Destination $Path -Force
    return $cleared
}

# --- identity ---------------------------------------------------------------------------------------
if (-not $ProductName -and $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
    $engine = & (Join-Path $PSScriptRoot 'Get-PsadtInstallerEngine.ps1') -Path $Path
    $ProductName = [string]$engine.ProductName
    $result.ProductName = $ProductName
}
if (-not $ProductName) { throw 'Nothing to go on: pass -ProductName or -Path.' }

# --- catalog ----------------------------------------------------------------------------------------
if (-not $CatalogPath) {
    $CatalogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'references\switch-catalog\logo-sources.json'
}
$entry = $null
if (-not (Test-Path -LiteralPath $CatalogPath)) {
    Add-Miss "no logo catalog at $CatalogPath"
}
else {
    try {
        $cat = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
        $entry = @($cat.entries | Where-Object { $_.productName -and $_.productName -eq $ProductName })[0]
    }
    catch { Add-Miss "the logo catalog is not readable JSON ($CatalogPath): $($_.Exception.Message)" }
}

if (-not $entry) {
    # Deliberately a miss with directions, not a guess. See the header.
    Add-Miss "no catalog entry for product '$ProductName'"
    Add-Warn ("Look it up once, then add an entry: logo.wine serves " +
        "https://www.logo.wine/a/logo/<Slug>/<Slug>-Logo.wine.svg (SVG, transparent, but can be years old); " +
        "Wikimedia Commons renders a PNG at a width you choose, but search the File: namespace rather than " +
        "guessing a name, and take thumburl verbatim (App. J.1). LOOK at the image before adding it.")
    return $result
}

$result.Found       = $true
$result.Source      = [string]$entry.source
$result.Url         = [string]$entry.url
$result.Fetch       = [string]$entry.fetch
$result.PostProcess = [string]$entry.postProcess
$result.Note        = [string]$entry.note

if (-not $OutFile) {
    Add-Warn 'no -OutFile given, so nothing was written - the entry above is what would have been used'
    return $result
}

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$ua = @{ 'User-Agent' = 'PSADT-pkg/1.0' }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('psadtlogo_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    switch ($result.Fetch) {

        'png-direct' {
            Invoke-WebRequest $result.Url -OutFile $OutFile -Headers $ua -UseBasicParsing
        }

        'webp-decode' {
            # System.Drawing has no webp codec; WIC does, and WPF is how PowerShell reaches WIC.
            Add-Type -AssemblyName PresentationCore, WindowsBase
            $src = Join-Path $tmp 'src.webp'
            Invoke-WebRequest $result.Url -OutFile $src -Headers $ua -UseBasicParsing
            $stream = [System.IO.File]::OpenRead($src)
            try {
                $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                    $stream,
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
                $fs = [System.IO.File]::Create($OutFile)
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            }
            finally { $stream.Dispose() }
        }

        'svg-rasterize' {
            # SVG has no decoder on Windows outside a browser engine. Edge ships with the OS.
            # --default-background-color=00000000 is the whole trick: without it every logo arrives on
            # opaque white and has to be keyed back out by hand, which is what this route avoids.
            $edge = @(
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            if (-not $edge) { throw 'msedge.exe was not found, and an SVG source needs it to rasterise' }

            $svg = Join-Path $tmp 'logo.svg'
            Invoke-WebRequest $result.Url -OutFile $svg -Headers $ua -UseBasicParsing

            # An <svg> inside a page is laid out by CSS, so hand it the exact box and nothing around it.
            $page = Join-Path $tmp 'page.html'
            $svgText = Get-Content -LiteralPath $svg -Raw
            $html = "<!doctype html><meta charset=`"utf-8`">" +
                    "<style>html,body{margin:0;padding:0;background:transparent}" +
                    "svg{display:block;width:${Size}px;height:${Size}px}</style>" + $svgText
            Set-Content -LiteralPath $page -Value $html -Encoding utf8

            $shot = Join-Path $tmp 'shot.png'
            $edgeArgs = @(
                '--headless=new', '--disable-gpu', '--hide-scrollbars',
                '--default-background-color=00000000',
                "--window-size=$Size,$Size",
                "--screenshot=$shot",
                ('--user-data-dir=' + (Join-Path $tmp 'ud')),
                ('file:///' + ($page -replace '\\', '/'))
            )
            & $edge @edgeArgs 2>$null | Out-Null
            if (-not (Test-Path -LiteralPath $shot)) { throw 'headless Edge produced no screenshot' }
            Copy-Item -LiteralPath $shot -Destination $OutFile -Force
        }

        default { throw "unknown fetch mode '$($result.Fetch)' in the catalog entry for '$ProductName'" }
    }

    if ($result.PostProcess -eq 'border-key') {
        Invoke-BorderKey -Path $OutFile -Tolerance 12 | Out-Null
    }
    elseif ($result.PostProcess) {
        throw "unknown postProcess '$($result.PostProcess)' in the catalog entry for '$ProductName'"
    }

    # --- verify what was actually produced ----------------------------------------------------------
    Add-Type -AssemblyName System.Drawing.Common
    $bmp = [System.Drawing.Bitmap]::FromFile($OutFile)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $result.Width = $w
        $result.Height = $h
        $corners = @(
            $bmp.GetPixel(0, 0).A, $bmp.GetPixel($w - 1, 0).A,
            $bmp.GetPixel(0, $h - 1).A, $bmp.GetPixel($w - 1, $h - 1).A)
        $result.CornerAlpha = $corners
        # REAL alpha, not merely a PNG that declares an alpha channel (App. J).
        $result.Transparent = (($corners | Measure-Object -Maximum).Maximum -eq 0)
    }
    finally { $bmp.Dispose() }

    $result.OutFile = $OutFile
    if ([math]::Min($result.Width, $result.Height) -lt 512) {
        Add-Warn "the logo is $($result.Width)x$($result.Height); App. J wants at least 512px for the Intune tile"
    }
    if (-not $result.Transparent) {
        Add-Warn 'the corners are not transparent - this mark sits on an opaque ground; add postProcess "border-key" to its catalog entry'
    }
    if ([math]::Abs($result.Width - $result.Height) -gt [math]::Max($result.Width, $result.Height) * 0.34) {
        Add-Warn 'the image is far from square, which the Intune tile crops badly'
    }
    Add-Warn 'Measured, not seen: look at the image before it ships (App. J).'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

return $result
