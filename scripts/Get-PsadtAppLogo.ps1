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
      * It never accepts its own output silently. Size, squareness, REAL corner alpha and - since 0.49.2 -
        how much of the canvas the mark actually fills are measured and returned; a caller that wants to
        ship the file still has to look at it (App. J).
      * It never writes -OutFile before the result is checked (0.49.2). Fetching, decoding and keying all
        happen in a scratch folder; the file is committed once, at the end, with a replace that throws.

    Measured 2026-09-27 on a real second version, and fixed here: headless Edge's launcher returned after
    169 ms and the screenshot landed about 1.5 s later (now: wait for the file to stop growing, and track
    Edge by its process tree); a vendor SVG with width/height but no viewBox rendered 68 px inside a
    1024 px canvas and passed every check (now: the viewBox is added, and the content box is measured);
    and the catalog matched productName exactly while the MSI ProductName carried the version (now: the
    app identity, vendor + name, is matched first).

    .PARAMETER ProductName
        The product as the binary reports it - Get-PsadtInstallerEngine.ps1 .ProductName, which is the
        same key the verified-switch store falls back on. Padding and doubled spaces are ignored.

    .PARAMETER Path
        An installer to read the product name out of instead of passing -ProductName.

    .PARAMETER Vendor
    .PARAMETER Name
        The operator's identity for the application (app.vendor / app.name). Matched against an entry's
        appKey before the product name, so the next version finds the same entry however its binary names
        itself.

    .PARAMETER ManifestPath
        A package's psadt-package.json, to take Vendor and Name from.

    .OUTPUTS
        PSCustomObject: ProductName, AppKey, MatchedBy, Found, Source, Url, Fetch, PostProcess, OutFile,
        Width, Height, Transparent, CornerAlpha, ContentBox, Fill, Note, Warnings, Misses.
#>
[CmdletBinding()]
param(
    [string]$ProductName,

    [string]$Path,

    [string]$Vendor,
    [string]$Name,
    [string]$ManifestPath,

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
    AppKey      = $null
    MatchedBy   = $null
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
    ContentBox  = $null
    Fill        = $null
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
    # A replace that THROWS. Move-Item -Force deleted the destination first and reported a failure only
    # as a non-terminating error.
    [System.IO.File]::Replace($tmpOut, $Path, [NullString]::Value)
    return $cleared
}

function Repair-SvgViewBox {
    <#
        An SVG root with numeric width/height but no viewBox has no coordinate system to scale: laid out in
        a 1024 px box it keeps its own size and draws a stamp in the corner of the canvas. Measured
        2026-09-27: a vendor mark with width="68.26667" rendered 68 px wide in 1024. With viewBox="0 0 W H"
        the same drawing fills the box. Only the ROOT element is touched, and only when both dimensions are
        plain numbers (px allowed) - a percentage or a physical unit says nothing about the drawing.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SvgText)
    $root = [regex]::Match($SvgText, '<svg\b[^>]*>', 'IgnoreCase')
    if (-not $root.Success) { return $SvgText }
    $tag = $root.Value
    if ($tag -match '\sviewBox\s*=') { return $SvgText }
    $wm = [regex]::Match($tag, '\swidth\s*=\s*["'']\s*([0-9]*\.?[0-9]+)\s*(px)?\s*["'']', 'IgnoreCase')
    $hm = [regex]::Match($tag, '\sheight\s*=\s*["'']\s*([0-9]*\.?[0-9]+)\s*(px)?\s*["'']', 'IgnoreCase')
    if (-not ($wm.Success -and $hm.Success)) { return $SvgText }
    $fixed = [regex]::Replace($tag, '^<svg\b', ('<svg viewBox="0 0 {0} {1}"' -f $wm.Groups[1].Value, $hm.Groups[1].Value), 'IgnoreCase')
    return $SvgText.Substring(0, $root.Index) + $fixed + $SvgText.Substring($root.Index + $root.Length)
}

function Measure-ContentBox {
    <#
        Where the mark actually is. Every earlier check - size, squareness, corner alpha - looks at the
        CANVAS, and a 68 px stamp in a transparent 1024 px canvas passes all of them. This scans inward
        from each edge for the first pixel that is not ground: alpha above 16 on a transparent image, or a
        colour away from the corner colour on an opaque one. Fill is the larger share of width or height
        the content spans. An image with no content at all is refused, not measured.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$AlphaFloor = 16, [int]$ColourTolerance = 24)

    Add-Type -AssemblyName System.Drawing.Common
    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
        $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stride = $bd.Stride
            $buf = New-Object byte[] ($stride * $h)
            [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        }
        finally { $bmp.UnlockBits($bd) }
    }
    finally { $bmp.Dispose() }

    # BGRA. The ground is what most corners show: transparent when at least two of the four are, else the
    # colour the mark was published on. One corner is not enough - a mark may touch it.
    $corners = @(0, (($w - 1) * 4), (($h - 1) * $stride), (($h - 1) * $stride + ($w - 1) * 4))
    $clear = (@($corners | Where-Object { $buf[$_ + 3] -le $AlphaFloor }).Count -ge 2)
    $g0 = $corners[0]
    $gb = [int]$buf[$g0]; $gg = [int]$buf[$g0 + 1]; $gr = [int]$buf[$g0 + 2]; $ga = [int]$buf[$g0 + 3]
    # One pass over a run of pixels (a row, or a column when the step is the stride). The pixel test is
    # inline on purpose: a scriptblock per pixel costs a million calls on a 1024 px canvas.
    $runHasInk = {
        param([int]$start, [int]$step, [int]$count)
        $o = $start
        for ($i = 0; $i -lt $count; $i++) {
            if ($clear) {
                if ($buf[$o + 3] -gt $AlphaFloor) { return $true }
            }
            else {
                $d = [int]$buf[$o] - $gb; if ($d -lt 0) { $d = -$d }
                $e = [int]$buf[$o + 1] - $gg; if ($e -lt 0) { $e = -$e }; if ($e -gt $d) { $d = $e }
                $e = [int]$buf[$o + 2] - $gr; if ($e -lt 0) { $e = -$e }; if ($e -gt $d) { $d = $e }
                $e = [int]$buf[$o + 3] - $ga; if ($e -lt 0) { $e = -$e }; if ($e -gt $d) { $d = $e }
                if ($d -gt $ColourTolerance) { return $true }
            }
            $o += $step
        }
        return $false
    }

    $top = -1
    for ($y = 0; $y -lt $h; $y++) { if (& $runHasInk ($y * $stride) 4 $w) { $top = $y; break } }
    if ($top -lt 0) { throw "the rendered image holds nothing visible ($w x $h, all ground) - the source did not draw, or drew outside the canvas" }
    $bottom = $top
    for ($y = $h - 1; $y -ge $top; $y--) { if (& $runHasInk ($y * $stride) 4 $w) { $bottom = $y; break } }
    $rows = $bottom - $top + 1
    $left = 0
    for ($x = 0; $x -lt $w; $x++) { if (& $runHasInk ($top * $stride + $x * 4) $stride $rows) { $left = $x; break } }
    $right = $left
    for ($x = $w - 1; $x -ge $left; $x--) { if (& $runHasInk ($top * $stride + $x * 4) $stride $rows) { $right = $x; break } }

    $cw = $right - $left + 1; $ch = $bottom - $top + 1
    $fill = [math]::Round([math]::Max($cw / $w, $ch / $h), 3)
    $warn = @()
    if ($fill -lt 0.6) { $warn += ("the mark fills only {0:P0} of the {1}x{2} canvas - a viewBox-less SVG or a padded source; the Intune tile will show a stamp" -f $fill, $w, $h) }
    $dx = [math]::Abs(($left + $cw / 2) - $w / 2) / $w
    $dy = [math]::Abs(($top + $ch / 2) - $h / 2) / $h
    if ($dx -gt 0.1 -or $dy -gt 0.1) { $warn += 'the mark sits off centre in its canvas' }
    return [pscustomobject]@{
        ContentBox = [pscustomobject]@{ X = $left; Y = $top; Width = $cw; Height = $ch }
        Fill       = $fill
        Warning    = $(if ($warn.Count) { $warn -join '; ' } else { $null })
    }
}

function Wait-FileStable {
    <#
        True once the file exists, is not empty, has kept one size over three polls, and can be opened
        exclusively - i.e. its writer is done. Headless Edge's launcher returns before its browser process
        writes the screenshot (169 ms against ~1.5 s, measured 2026-09-27), so "the call returned" is not
        "the file is there".
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSeconds = 30, [int]$PollMilliseconds = 250, [int]$StablePolls = 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = -1L; $same = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $len = (Get-Item -LiteralPath $Path).Length
            if ($len -gt 0 -and $len -eq $last) { $same++ } else { $same = 0 }
            $last = $len
            if ($same -ge $StablePolls - 1) {
                try { $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None'); $fs.Dispose(); return $true } catch { $same = 0 }
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return $false
}

function Find-LogoCatalogEntry {
    <#
        The app identity first (appKey = vendor + name, _AppKey.ps1 - it survives a version bump), then the
        product name with padding and doubled spaces ignored. Exact otherwise: no fuzzy match, because a
        near-miss served with confidence is how a wrong logo reaches a tile nobody inspects.
    #>
    param([object[]]$Entries, [string]$AppKey, [string]$ProductName)
    if ($AppKey) {
        $hit = @($Entries | Where-Object { $_.appKey -and ([string]$_.appKey) -eq $AppKey })[0]
        if ($hit) { return [pscustomobject]@{ Entry = $hit; MatchedBy = 'appKey' } }
    }
    if ($ProductName) {
        $want = (([string]$ProductName) -replace '\s+', ' ').Trim()
        $hit = @($Entries | Where-Object { $_.productName -and ((([string]$_.productName) -replace '\s+', ' ').Trim()) -eq $want })[0]
        if ($hit) { return [pscustomobject]@{ Entry = $hit; MatchedBy = 'productName' } }
    }
    return $null
}

function Get-EdgeProcessTree {
    # The Edge processes THIS run started: the ones whose command line carries our private user-data-dir,
    # and everything below them. Only the browser and crashpad carry the flag; renderers and the GPU
    # process are found through ParentProcessId. Never a name match - the operator's own Edge is running.
    param([Parameter(Mandatory)][string]$Marker)
    $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue)
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($p in $all) {
        if ([string]$p.CommandLine -and ([string]$p.CommandLine).IndexOf($Marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$ids.Add([int]$p.ProcessId) }
    }
    do {
        $grew = $false
        foreach ($p in $all) {
            if (-not $ids.Contains([int]$p.ProcessId) -and $ids.Contains([int]$p.ParentProcessId)) { [void]$ids.Add([int]$p.ProcessId); $grew = $true }
        }
    } while ($grew)
    return @($ids)
}

function Save-LogoOutput {
    # The single write to -OutFile: a sibling temp copy, then a replace that THROWS - the original stays
    # when it cannot be replaced, and the caller hears about it.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $staged = "$Destination.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [System.IO.File]::Copy($Source, $staged, $true)
        if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::Replace($staged, $Destination, [NullString]::Value) }
        else { [System.IO.File]::Move($staged, $Destination) }
    }
    catch { throw "the logo was NOT written to $Destination - $($_.Exception.Message)" }
    finally { if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue } }
}

# --- identity ---------------------------------------------------------------------------------------
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }
    try { $mfLogo = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "psadt-package.json is malformed: $($_.Exception.Message)" }
    if (-not $Vendor) { $Vendor = [string]$mfLogo.app.vendor }
    if (-not $Name) { $Name = [string]$mfLogo.app.name }
}
if (-not $ProductName -and $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
    $engine = & (Join-Path $PSScriptRoot 'Get-PsadtInstallerEngine.ps1') -Path $Path
    $ProductName = [string]$engine.ProductName
}
. (Join-Path $PSScriptRoot '_AppKey.ps1')
$appKey = ConvertTo-PsadtAppKey -Vendor $Vendor -Name $Name
if (-not $ProductName -and $Name) { $ProductName = $Name }
$result.ProductName = $ProductName
$result.AppKey = $(if ($appKey) { $appKey } else { $null })
if (-not $ProductName -and -not $appKey) { throw 'Nothing to go on: pass -ProductName, -Path, -Vendor/-Name or -ManifestPath.' }

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
        $hit = Find-LogoCatalogEntry -Entries @($cat.entries) -AppKey $appKey -ProductName $ProductName
        if ($hit) { $entry = $hit.Entry; $result.MatchedBy = $hit.MatchedBy }
    }
    catch { Add-Miss "the logo catalog is not readable JSON ($CatalogPath): $($_.Exception.Message)" }
}

if (-not $entry) {
    # Deliberately a miss with directions, not a guess. See the header.
    Add-Miss ("no catalog entry for product '$ProductName'" + $(if ($appKey) { " or app '$appKey'" } else { '' }))
    Add-Warn ("Look it up once, then add an entry: logo.wine serves " +
        "https://www.logo.wine/a/logo/<Slug>/<Slug>-Logo.wine.svg (SVG, transparent, but can be years old); " +
        "Wikimedia Commons renders a PNG at a width you choose, but search the File: namespace rather than " +
        "guessing a name, and take thumburl verbatim (App. J.1). Give the entry an appKey (vendor + name, " +
        "lowercase) so the next version finds it too. LOOK at the image before adding it.")
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

$ua = @{ 'User-Agent' = 'PSADT-pkg/1.0' }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('psadtlogo_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
# Everything below writes into $tmp. -OutFile is written once, after every check (Save-LogoOutput).
$work = Join-Path $tmp 'logo.png'
$userData = Join-Path $tmp 'ud'

try {
    switch ($result.Fetch) {

        'png-direct' {
            Invoke-WebRequest $result.Url -OutFile $work -Headers $ua -UseBasicParsing
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
                $fs = [System.IO.File]::Create($work)
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

            # An <svg> inside a page is laid out by CSS, so hand it the exact box and nothing around it -
            # and a viewBox, without which the drawing keeps its own size inside that box.
            $page = Join-Path $tmp 'page.html'
            $svgRaw = Get-Content -LiteralPath $svg -Raw
            $svgText = Repair-SvgViewBox -SvgText $svgRaw
            if ($svgText -ne $svgRaw) { Add-Warn 'the source SVG has no viewBox; one was added from its width and height so the mark scales to the canvas' }
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
                ('--user-data-dir=' + $userData),
                ('file:///' + ($page -replace '\\', '/'))
            )
            & $edge @edgeArgs 2>$null | Out-Null
            # The launcher returning says nothing about the screenshot: the browser it handed over to writes
            # it later. Wait for the file to be complete, then for our own Edge processes to go.
            if (-not (Wait-FileStable -Path $shot -TimeoutSeconds 30)) { throw 'headless Edge produced no screenshot within 30 seconds' }
            $until = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $until -and @(Get-EdgeProcessTree -Marker $userData).Count -gt 0) { Start-Sleep -Milliseconds 250 }
            Copy-Item -LiteralPath $shot -Destination $work -Force
        }

        default { throw "unknown fetch mode '$($result.Fetch)' in the catalog entry for '$ProductName'" }
    }

    if ($result.PostProcess -eq 'border-key') {
        Invoke-BorderKey -Path $work -Tolerance 12 | Out-Null
    }
    elseif ($result.PostProcess) {
        throw "unknown postProcess '$($result.PostProcess)' in the catalog entry for '$ProductName'"
    }

    # --- verify what was actually produced ----------------------------------------------------------
    Add-Type -AssemblyName System.Drawing.Common
    $bmp = [System.Drawing.Bitmap]::FromFile($work)
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

    # What the canvas holds, not just the canvas. Throws on an image with nothing in it.
    $box = Measure-ContentBox -Path $work
    $result.ContentBox = $box.ContentBox
    $result.Fill = $box.Fill
    if ($box.Warning) { Add-Warn $box.Warning }

    if ([math]::Min($result.Width, $result.Height) -lt 512) {
        Add-Warn "the logo is $($result.Width)x$($result.Height); App. J wants at least 512px for the Intune tile"
    }
    if (-not $result.Transparent) {
        Add-Warn 'the corners are not transparent - this mark sits on an opaque ground; add postProcess "border-key" to its catalog entry'
    }
    if ([math]::Abs($result.Width - $result.Height) -gt [math]::Max($result.Width, $result.Height) * 0.34) {
        Add-Warn 'the image is far from square, which the Intune tile crops badly'
    }

    Save-LogoOutput -Source $work -Destination $OutFile
    $result.OutFile = $OutFile
    Add-Warn 'Measured, not seen: look at the image before it ships (App. J).'
}
finally {
    # Our Edge processes still hold files under $tmp; stop what is left of THEM before removing it.
    $leftover = @(Get-EdgeProcessTree -Marker $userData)
    foreach ($id in $leftover) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

return $result
