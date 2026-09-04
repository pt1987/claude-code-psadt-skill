<#
.SYNOPSIS
    Creates/updates config.json (deep partial merge) and, optionally, DPAPI-encrypts the client secret.

.DESCRIPTION
    Resolves the config home through Get-PsadtConfig.ps1 (explicit -SkillRoot > $env:PSADT_DEPLOY_HOME >
    %LOCALAPPDATA%\psadt-deploy, with a read-only legacy fallback next to scripts\ that is still written to
    until it has been migrated), then merges -Updates into config.json (creating it, and its folder, if
    absent). Dotted-path keys let a single leaf or a whole sub-tree be set without rewriting the file;
    -Remove deletes leaves the same way. A -Secret is DPAPI-encrypted (CurrentUser scope) to secret.dpapi
    beside the resolved config and is never logged or returned. Writes config.json as UTF-8.

.PARAMETER SkillRoot
    Config home override. Default empty = resolve as described above.

.PARAMETER Updates
    Hashtable of dotted-path -> value, e.g. @{ 'paths.packageRoot' = 'c:\p'; 'intune.groups.naming' = @{...} }.
    Intermediate nodes are created as needed; existing siblings are preserved.

.PARAMETER Remove
    Dotted-path keys to delete, e.g. @('intune.certThumbprint'). Siblings are kept; a key that does not
    exist is a no-op. Applied after -Updates.

.PARAMETER Secret
    SecureString client secret; DPAPI-encrypted (CurrentUser) to secret.dpapi. Never logged or returned.

.EXAMPLE
    Set-PsadtConfig.ps1 -Updates @{ 'author.person' = 'Jane Doe'; 'author.company' = 'Contoso' }

.EXAMPLE
    Set-PsadtConfig.ps1 -Remove @('intune.certThumbprint')
#>
[CmdletBinding()]
param(
    [string]$SkillRoot,
    [hashtable]$Updates = @{},
    [string[]]$Remove = @(),
    [System.Security.SecureString]$Secret
)

$probe      = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
$configPath = $probe.Path
$configHome = $probe.Home
$dir = Split-Path -Parent $configPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

function ConvertTo-HashtableDeep($obj) {
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    return $obj
}
$config = if (Test-Path -LiteralPath $configPath) {
    try { ConvertTo-HashtableDeep (Get-Content $configPath -Raw | ConvertFrom-Json) }
    catch { throw "config.json is malformed and cannot be safely updated: $($_.Exception.Message). Fix or delete it, then re-run." }
} else { @{ version = 1 } }
if (-not $config.ContainsKey('version')) { $config['version'] = 1 }

foreach ($key in $Updates.Keys) {
    $segs = $key -split '\.'
    $node = $config
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        if (-not ($node[$segs[$i]] -is [hashtable])) { $node[$segs[$i]] = @{} }
        $node = $node[$segs[$i]]
    }
    $node[$segs[-1]] = $Updates[$key]
}

foreach ($key in $Remove) {
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $segs = $key -split '\.'
    $node = $config
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        if (-not ($node[$segs[$i]] -is [hashtable])) { $node = $null; break }
        $node = $node[$segs[$i]]
    }
    if ($node -is [hashtable]) { $node.Remove($segs[-1]) }
}

$config | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding UTF8

if ($Secret) {
    $enc = ConvertFrom-SecureString $Secret
    Set-Content -Path (Join-Path $configHome 'secret.dpapi') -Value $enc -Encoding ASCII -NoNewline
}
