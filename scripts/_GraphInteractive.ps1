<#
.SYNOPSIS
    Shared INTERACTIVE (delegated) Microsoft Graph sign-in via WAM (Windows Web Account Manager broker).
    Dot-source AFTER _GraphCommon.ps1 (uses Write-Info / Write-Warn2). Defines functions only.

.DESCRIPTION
    Extracted from New-PsadtEntraApp.ps1 so the bootstrap AND the policy scripts (New-IntuneFirewallPolicy.ps1,
    New-IntuneTrustedCertPolicy.ps1) share ONE WAM implementation instead of copy-pasting it (the drift problem
    called out in _GraphCommon.ps1). WAM shows the native Windows sign-in window and reuses SSO / the Primary
    Refresh Token - NO device code. Needs the MSAL.NET broker assemblies; they are auto-located in the global
    NuGet cache or downloaded once (pinned) to %LOCALAPPDATA%\PsadtIntune\msal. Windows only.

    Public entry point:
        Get-InteractiveGraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All') [-TenantId <id>]
    Returns the raw delegated access_token string. Throws (does NOT fall back to device code) if WAM is unavailable.

.NOTES
    Part of the psadt-deploy skill. No side effects on import beyond defining functions/constants.
#>

# Pinned, known-good MSAL.NET broker package set (auto-located or downloaded once).
$script:MsalVersions  = @{ Client = '4.66.2'; Broker = '4.66.2'; Native = '0.16.2'; Abstractions = '6.35.0' }
$script:MsalCacheRoot = Join-Path $env:LOCALAPPDATA 'PsadtIntune\msal'
$script:GraphCliClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # "Microsoft Graph Command Line Tools" (public)
$script:MsalReady = $false

function Save-NuGetPackage {
    param([string]$Id, [string]$Version, [string]$DestDir)
    $idl = $Id.ToLower(); $verl = $Version.ToLower()
    $url = "https://api.nuget.org/v3-flatcontainer/$idl/$verl/$idl.$verl.nupkg"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$idl.$verl.nupkg"
    Write-Info "downloading $Id $Version ..."
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $DestDir)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Get-PackageDir {
    param([string]$Id, [string]$Version, [string]$LocalRoot)
    $global = Join-Path $env:USERPROFILE ".nuget\packages\$Id\$Version"
    if (Test-Path $global) { return $global }
    $local = Join-Path $LocalRoot "$Id\$Version"
    if ((Test-Path $local) -and (Get-ChildItem $local -ErrorAction SilentlyContinue)) { return $local }
    Save-NuGetPackage -Id $Id -Version $Version -DestDir $local
    return $local
}

function Initialize-MsalBroker {
    param([hashtable]$Versions = $script:MsalVersions, [string]$CacheRoot = $script:MsalCacheRoot)
    if ($script:MsalReady) { return $true }
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        throw "WAM is only available on Windows."
    }
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $clientTfm = if ($isCore) { 'net6.0' }        else { 'net462' }
    $brokerTfm = if ($isCore) { 'netstandard2.0' } else { 'net462' }
    $nativeTfm = if ($isCore) { 'netstandard2.0' } else { 'net461' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
        'Arm64' { 'win-arm64' } 'X86' { 'win-x86' } default { 'win-x64' }
    }

    # Reuse a 4.66.x client already in the global cache (avoids a download) before falling back to pinned.
    $clientVer = $Versions.Client
    $cb = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.identity.client"
    if (-not (Test-Path (Join-Path $cb $clientVer)) -and (Test-Path $cb)) {
        $newer = Get-ChildItem $cb -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '4.66.*' -and (Test-Path (Join-Path $_.FullName "lib\$clientTfm\Microsoft.Identity.Client.dll")) } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        if ($newer) { $clientVer = $newer.Name }
    }

    $abstrDll  = Join-Path (Get-PackageDir 'microsoft.identitymodel.abstractions'    $Versions.Abstractions $CacheRoot) "lib\$clientTfm\Microsoft.IdentityModel.Abstractions.dll"
    $clientDll = Join-Path (Get-PackageDir 'microsoft.identity.client'              $clientVer        $CacheRoot) "lib\$clientTfm\Microsoft.Identity.Client.dll"
    $brokerDll = Join-Path (Get-PackageDir 'microsoft.identity.client.broker'       $Versions.Broker  $CacheRoot) "lib\$brokerTfm\Microsoft.Identity.Client.Broker.dll"
    $nativePkg =           (Get-PackageDir 'microsoft.identity.client.nativeinterop' $Versions.Native  $CacheRoot)
    $nativeMgr = Join-Path $nativePkg "lib\$nativeTfm\Microsoft.Identity.Client.NativeInterop.dll"
    $nativeRun = Join-Path $nativePkg "runtimes\$arch\native"

    foreach ($f in @($abstrDll, $clientDll, $brokerDll, $nativeMgr)) {
        if (-not (Test-Path $f)) { throw "MSAL assembly not found: $f" }
    }
    if (-not (Test-Path $nativeRun)) { throw "MSAL native runtime folder not found: $nativeRun" }

    # Stage the native broker dll into a private folder on PATH (never mutate the shared NuGet cache).
    $runDir = Join-Path $CacheRoot "native\$arch"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    Get-ChildItem $nativeRun -Filter 'msalruntime*.dll' | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $runDir $_.Name) -Force
    }
    if (-not (Test-Path (Join-Path $runDir 'msalruntime.dll'))) {
        $alt = Get-ChildItem $runDir -Filter 'msalruntime*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) { Copy-Item $alt.FullName (Join-Path $runDir 'msalruntime.dll') -Force }
    }
    if ($env:PATH -notlike "*$runDir*") { $env:PATH = "$runDir;$env:PATH" }

    [System.Reflection.Assembly]::LoadFrom($abstrDll)  | Out-Null
    [System.Reflection.Assembly]::LoadFrom($clientDll) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($nativeMgr) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($brokerDll) | Out-Null

    if (-not ([System.Management.Automation.PSTypeName]'PsadtNative.Win').Type) {
        Add-Type -Namespace PsadtNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]   public static extern System.IntPtr GetForegroundWindow();
'@
    }

    $script:MsalReady = $true
    return $true
}

function Get-WamToken {
    param([string]$Tenant, [string[]]$GraphScopes, [string]$ClientId = $script:GraphCliClientId)
    $authority = "https://login.microsoftonline.com/$Tenant"
    $builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId).WithAuthority($authority)
    $bo = New-Object 'Microsoft.Identity.Client.BrokerOptions' -ArgumentList ([Microsoft.Identity.Client.BrokerOptions+OperatingSystems]::Windows)
    $builder = [Microsoft.Identity.Client.Broker.BrokerExtension]::WithBroker($builder, $bo)
    $pca = $builder.Build()

    $hwnd = [PsadtNative.Win]::GetConsoleWindow()
    if ($hwnd -eq [System.IntPtr]::Zero) { $hwnd = [PsadtNative.Win]::GetForegroundWindow() }

    Write-Host "    A Windows sign-in window (Web Account Manager) will open ..." -ForegroundColor Gray
    $req = $pca.AcquireTokenInteractive([string[]]$GraphScopes)
    $req = $req.WithParentActivityOrWindow($hwnd)
    $req = $req.WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
    $result = $req.ExecuteAsync().GetAwaiter().GetResult()
    return [pscustomobject]@{ access_token = $result.AccessToken }
}

function Get-InteractiveGraphToken {
    # Public entry point: WAM-only delegated sign-in. Returns the raw access_token string.
    param(
        [string[]]$Scopes = @('https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All'),
        [string]$TenantId = 'organizations',
        [string]$ClientId = $script:GraphCliClientId
    )
    Initialize-MsalBroker | Out-Null
    Write-Info "Interactive sign-in: WAM (Windows Web Account Manager)."
    return (Get-WamToken -Tenant $TenantId -GraphScopes $Scopes -ClientId $ClientId).access_token
}
