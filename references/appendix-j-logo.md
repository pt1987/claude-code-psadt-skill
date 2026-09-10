# Appendix J: App logo - acquisition + verification

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix J: App logo - acquisition + verification

The logo is uploaded separately (Intune **App information** tab / Phase 9); it is NOT part of the
`.intunewin` (no repack on logo change). Obtain the **REAL** application logo (PNG, transparent, >=512px,
square preferred) → `<pkg>\Assets\<App>-Logo.png` AND a copy in `Output\<App>\`. **Never** ship the PSADT
default `Assets\AppIcon.png`/`Banner.Classic.png` (see H.10 — the upload script blocks them by SHA256).

### J.1 License-clear sources, in priority order

1. **Microsoft products:** `https://learn.microsoft.com/en-us/<product>/media/index/<product>.png`
   (transparent PNG, direct download; `<product>` lowercase, e.g. `powershell`, `sqlserver`, `azure`).
2. **Other vendors:** official vendor/project source (e.g. `apache.org/logos/res/<project>/`).
3. **Wikimedia Commons** (stable URLs, SVG rendered server-side as transparent PNG).
   **Two rules, both learned the hard way (2026-09-05, twice in one session):**
   - **Never guess the file name.** `File:<App> Logo.svg` is as likely to 404 as to exist. Search the File
     namespace first and take the title from the result:
     ```powershell
     $q = 'https://commons.wikimedia.org/w/api.php?action=query&list=search&srsearch=' +
          [uri]::EscapeDataString('<App> logo') + '&srnamespace=6&srlimit=10&format=json'
     (Invoke-RestMethod $q -Headers @{'User-Agent'='PSADT-pkg/1.0'}).query.search.title
     ```
   - **Only listed thumbnail widths are served.** A width the wiki has not pre-rendered returns
     **HTTP 400 "Use thumbnail sizes listed on ..."**, not an image - `1024px-` fails where `1280px-`
     works. Do not hand-build the URL: take `thumburl` from the API response verbatim (it names a width
     that is guaranteed to exist) and strip any `?utm_*` query string.

   ```powershell
   $api = "https://commons.wikimedia.org/w/api.php?action=query&titles=$([uri]::EscapeDataString('File:<Logo>.svg'))&prop=imageinfo&iiprop=url&iiurlwidth=1024&format=json"
   $thumb = ((Invoke-RestMethod $api -Headers @{'User-Agent'='PSADT-pkg/1.0'}).query.pages.PSObject.Properties.Value).imageinfo[0].thumburl
   Invoke-WebRequest $thumb -OutFile '<pkg>\Assets\<App>-Logo.png' -Headers @{'User-Agent'='PSADT-pkg/1.0'}
   ```
   Avoid third-party PNG portals (stickpng, toppng, nicepng, ...) — hotlink protection/ads/poor quality.
4. **MSI Icon-table fallback** (when web download fails). `Get-PsadtMsiFacts.ps1` lists the `Icon` table
   entries, so check there first whether the MSI even carries one.
   **Check the frame table before trusting this route.** The reader below assumes a 32-bpp DIB frame; an
   older installer often carries nothing better than **48x48 at 8 bpp** (PuTTY 0.85 does), and then
   `FromDib32` throws *"Source array was not long enough"* because a palette frame is a fraction of the
   expected size. Read the ICO directory first (`bpp` sits at offset `base+6` of each 16-byte entry) and
   fall back to a web source when the largest frame is below ~256px or not 32 bpp — a correct 48px icon is
   still too small for the Intune tile.
   MSI installers embed `.ico` files in an `Icon`
   table. `System.Drawing.Icon` silently falls back to 48x48 when the 256x256 frame is PNG-compressed inside
   the `.ico` on .NET 4.x — parse the raw ICO binary and extract the largest frame directly:
   ```powershell
   Add-Type -AssemblyName System.Drawing
   Add-Type -TypeDefinition @'
   using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
   public class IcoDibReader {
       public static Bitmap FromDib32(byte[] dib, int width, int height) {
           int pixelDataSize = width * height * 4;
           var pixels = new byte[pixelDataSize];
           Array.Copy(dib, 40, pixels, 0, pixelDataSize);
           var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
           var bd = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
           int rb = width * 4;
           for (int r = 0; r < height; r++) Marshal.Copy(pixels, (height-1-r)*rb, IntPtr.Add(bd.Scan0, r*bd.Stride), rb);
           bmp.UnlockBits(bd); return bmp;
       }
   }
   '@ -ReferencedAssemblies 'System.Drawing'
   $tmpDir = "$env:TEMP\MsiIconExport"; New-Item $tmpDir -ItemType Directory -Force | Out-Null
   $db = [System.Activator]::CreateInstance([System.Type]::GetTypeFromProgID('WindowsInstaller.Installer')).OpenDatabase('<path-to.msi>', 0)
   $db.Export('Icon', $tmpDir, 'Icon.idt')   # streams export as <IconName>.ico.ibd under a subfolder 'Icon'
   $icoPath = Get-ChildItem "$tmpDir\Icon" -Filter '*.ibd' | Sort-Object Length -Descending | Select-Object -ExpandProperty FullName -First 1
   $allBytes = [System.IO.File]::ReadAllBytes($icoPath)
   $count = [BitConverter]::ToUInt16($allBytes, 4); $bestW = 0; $bestOff = 0; $bestSize = 0
   for ($i = 0; $i -lt $count; $i++) {
       $base = 6 + $i * 16; $w = [int]$allBytes[$base]; if ($w -eq 0) { $w = 256 }
       if ($w -gt $bestW) { $bestW = $w; $bestOff = [BitConverter]::ToUInt32($allBytes, $base+12); $bestSize = [BitConverter]::ToUInt32($allBytes, $base+8) }
   }
   $frame = New-Object byte[] $bestSize; [Array]::Copy($allBytes, $bestOff, $frame, 0, $bestSize)
   if ($frame[0] -eq 0x89 -and $frame[1] -eq 0x50) {
       [System.IO.File]::WriteAllBytes('<output>.png', $frame)  # PNG-compressed frame: write directly
   } else {
       $biH = [Math]::Abs([BitConverter]::ToInt32($frame, 8)) / 2
       $bmp = [IcoDibReader]::FromDib32($frame, $bestW, [int]$biH)
       $bmp.Save('<output>.png', [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
   }
   Remove-Item $tmpDir -Recurse -Force
   ```

### J.2 Verify (resolution + ACTUAL transparency + correct brand)

`IsAlphaPixelFormat` only says the pixel *format* supports alpha — it is True even for a fully opaque image
(a 7-Zip SVG rendered with an opaque black background still reported `Alpha=True`). Sample a real corner pixel:
```powershell
Add-Type -AssemblyName System.Drawing
$b=[System.Drawing.Bitmap]::FromFile('<png>')
$c=$b.GetPixel(0,0); "{0}x{1}  cornerAlpha={2} (0=transparent,255=opaque) RGB=({3},{4},{5})" -f $b.Width,$b.Height,$c.A,$c.R,$c.G,$c.B; $b.Dispose()
```
Then **actually look at the image** to confirm it is the app's brand, not the PSADT default. Transparent
(cornerAlpha=0) is preferred; an opaque-but-correct logo is acceptable (square it on its own background colour).
The WRONG image is never acceptable.

---
