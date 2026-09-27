function New-TempSkillRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("psadtskill_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts')    -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'tools')      -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'references') -Force | Out-Null
    $srcScripts = Join-Path $PSScriptRoot '..\scripts'
    if (Test-Path $srcScripts) { Copy-Item "$srcScripts\*" (Join-Path $root 'scripts') -Force }
    return $root
}
function Remove-TempSkillRoot([string]$Path) {
    if ($Path -and (Test-Path $Path)) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

# Returns the source text of a single named function defined inside a script file, WITHOUT executing the
# script's (side-effecting) top-level body. Used to unit-test internal helpers of script-style .ps1 files:
#   . ([scriptblock]::Create((Get-ScriptFunctionText -Path $s -Name 'Resolve-GroupName')))
function Get-ScriptFunctionText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "Function [$Name] not found in $Path" }
    return $fn.Extent.Text
}

# --- Binary fixtures -------------------------------------------------------------------------------
# tests/ ships no binary files (see the scope note in Get-PsadtMsiFacts.Tests.ps1), so installer shapes
# are synthesised here at runtime. Concatenating byte arrays with + yields Object[], and an Object[]
# holding byte[] elements silently fails every [byte[]] parameter and WriteAllBytes call - hence the
# explicit flattening.
function Join-Bytes {
    param([Parameter(ValueFromRemainingArguments)][object[]]$Parts)
    $list = New-Object System.Collections.Generic.List[byte]
    foreach ($p in $Parts) { foreach ($b in $p) { $list.Add([byte]$b) } }
    return , $list.ToArray()
}
function New-Pad([int]$Count) { return (New-Object byte[] $Count) }
function New-Ascii([string]$Text) { return [System.Text.Encoding]::ASCII.GetBytes($Text) }
function New-Blob([string]$Text) { return (Join-Bytes (New-Pad 64) (New-Ascii $Text) (New-Pad 64)) }

# Minimal but structurally valid PE32+: DOS stub, PE signature, COFF header, an optional header of the
# declared size, a section table with the requested names, one 512-byte raw block per section, and an
# optional overlay after the last section. That is the shape Get-PsadtInstallerEngine.ps1 navigates.
function New-TestPe {
    param(
        [string[]]$SectionNames = @('.text'),
        [byte[]]$Overlay = @(),
        [byte[]]$FirstSectionData = @()
    )
    $peOff = 0x80
    $optSize = 240
    $n = $SectionNames.Count
    $sectTableOff = $peOff + 4 + 20 + $optSize
    $sectDataStart = [int]([math]::Ceiling(($sectTableOff + 40 * $n) / 512.0) * 512)
    $buf = New-Object byte[] ($sectDataStart + ($n * 512))

    $buf[0] = 0x4D; $buf[1] = 0x5A
    [BitConverter]::GetBytes([uint32]$peOff).CopyTo($buf, 0x3C)
    $buf[$peOff] = 0x50; $buf[$peOff + 1] = 0x45

    $coff = $peOff + 4
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($buf, $coff)
    [BitConverter]::GetBytes([uint16]$n).CopyTo($buf, $coff + 2)
    [BitConverter]::GetBytes([uint16]$optSize).CopyTo($buf, $coff + 16)
    [BitConverter]::GetBytes([uint16]0x0022).CopyTo($buf, $coff + 18)
    [BitConverter]::GetBytes([uint16]0x020B).CopyTo($buf, $coff + 20)

    for ($i = 0; $i -lt $n; $i++) {
        $off = $sectTableOff + ($i * 40)
        $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($SectionNames[$i])
        for ($b = 0; $b -lt [math]::Min(8, $nameBytes.Length); $b++) { $buf[$off + $b] = $nameBytes[$b] }
        [BitConverter]::GetBytes([uint32]512).CopyTo($buf, $off + 8)
        [BitConverter]::GetBytes([uint32](0x1000 * ($i + 1))).CopyTo($buf, $off + 12)
        [BitConverter]::GetBytes([uint32]512).CopyTo($buf, $off + 16)
        [BitConverter]::GetBytes([uint32]($sectDataStart + ($i * 512))).CopyTo($buf, $off + 20)
    }
    if ($FirstSectionData.Length -gt 0) {
        [Array]::Copy($FirstSectionData, 0, $buf, $sectDataStart, [math]::Min($FirstSectionData.Length, 512))
    }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('engine_' + [guid]::NewGuid().ToString('N') + '.exe')
    $stream = [System.IO.File]::Create($path)
    try {
        $stream.Write($buf, 0, $buf.Length)
        if ($Overlay.Length -gt 0) { $stream.Write($Overlay, 0, $Overlay.Length) }
    }
    finally { $stream.Dispose() }
    return $path
}

# A file that Get-PsadtInstallerEngine.ps1 will call an MSI: the compound-file header is the marker.
function New-TestCfb {
    param([string]$Extension = '.msi')
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('engine_' + [guid]::NewGuid().ToString('N') + $Extension)
    [System.IO.File]::WriteAllBytes($path, (Join-Bytes (0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) (New-Pad 512)))
    return $path
}

# --- A fake Intune tenant (0.49.3) -------------------------------------------------------------------
# The tenant-writing scripts were tested only against their SOURCE, so what they record after a write -
# and whether a note still matches the assignments it describes - was never exercised. This is the small
# part of Graph they use, as state: apps, groups, assignments, supersedence edges and notes. Every call is
# logged, and an unknown route THROWS, so a script that starts calling something new fails its test
# instead of passing against a silent stub. Use it with a stub + Mock (a Pester mock beats the function the
# script dot-sources from _GraphCommon.ps1):
#     function Invoke-Graph { param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [int]$Depth = 20) }
#     Mock Invoke-Graph { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body }
function New-FakeIntuneTenant {
    [pscustomobject]@{
        Apps          = @{}   # id -> app object
        Groups        = @{}   # id -> displayName
        Assignments   = @{}   # appId -> List of @{ id; intent; target }
        Relationships = @{}   # appId -> List of relationship objects
        Calls         = New-Object System.Collections.Generic.List[string]
    }
}
function Add-FakeApp {
    param([Parameter(Mandatory)][string]$Id, [string]$Name = 'Widget', [string]$Version = '1.0', [string]$Notes = '')
    $global:PsadtFakeTenant.Apps[$Id] = [pscustomobject]@{
        '@odata.type' = '#microsoft.graph.win32LobApp'; id = $Id; displayName = $Name; displayVersion = $Version; notes = $Notes
    }
    $global:PsadtFakeTenant.Assignments[$Id] = New-Object System.Collections.Generic.List[object]
    $global:PsadtFakeTenant.Relationships[$Id] = New-Object System.Collections.Generic.List[object]
}
function Add-FakeGroup {
    param([Parameter(Mandatory)][string]$Name)
    $id = [guid]::NewGuid().ToString()
    $global:PsadtFakeTenant.Groups[$id] = $Name
    return $id
}
function Add-FakeAssignment {
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$Intent, [Parameter(Mandatory)][string]$GroupId)
    $global:PsadtFakeTenant.Assignments[$AppId].Add([pscustomobject]@{
            id = [guid]::NewGuid().ToString(); intent = $Intent
            target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId }
        })
}
# Lists are handed out with .ToArray(), never @(): @() around an EMPTY Generic.List throws "Argument types
# do not match" (the trap Get-PsadtInstallerEngine.ps1 documents).
function Invoke-FakeGraph {
    param([string]$Method, [string]$Uri, $Body)
    $t = $global:PsadtFakeTenant
    $t.Calls.Add("$Method $Uri")
    $path = ($Uri -replace '^https://graph\.microsoft\.com/(beta|v1\.0)', '')
    $rel = [regex]::Match($path, '^/deviceAppManagement/mobileApps/([0-9a-fA-F-]{36})(/.*)?$')
    if ($rel.Success) {
        $appId = $rel.Groups[1].Value; $sub = $rel.Groups[2].Value
        if (-not $t.Apps.ContainsKey($appId)) { throw "fake graph: 404 - app $appId is not in this tenant" }
        switch -Regex ($sub) {
            '^$' {
                if ($Method -eq 'GET') { return $t.Apps[$appId] }
                if ($Method -eq 'PATCH') { if ($null -ne $Body.notes) { $t.Apps[$appId].notes = [string]$Body.notes }; return $null }
            }
            '^/assignments$' {
                if ($Method -eq 'GET') { return [pscustomobject]@{ value = $t.Assignments[$appId].ToArray() } }
                if ($Method -eq 'POST') {
                    Add-FakeAssignment -AppId $appId -Intent ([string]$Body.intent) -GroupId ([string]$Body.target.groupId)
                    return [pscustomobject]@{}
                }
            }
            '^/assignments/([0-9a-fA-F-]{36})$' {
                if ($Method -eq 'DELETE') {
                    $aid = $Matches[1]
                    $hit = @($t.Assignments[$appId] | Where-Object { $_.id -eq $aid })
                    if (-not $hit.Count) { throw "fake graph: 404 - assignment $aid" }
                    [void]$t.Assignments[$appId].Remove($hit[0])
                    return $null
                }
            }
            '^/relationships$' {
                if ($Method -eq 'GET') { return [pscustomobject]@{ value = $t.Relationships[$appId].ToArray() } }
            }
            '^/updateRelationships$' {
                if ($Method -eq 'POST') {
                    $t.Relationships[$appId] = New-Object System.Collections.Generic.List[object]
                    foreach ($r in @($Body.relationships)) {
                        $child = $t.Apps[[string]$r.targetId]
                        $t.Relationships[$appId].Add([pscustomobject]@{
                                '@odata.type' = [string]$r.'@odata.type'; targetId = [string]$r.targetId; targetType = 'child'
                                supersedenceType = [string]$r.supersedenceType
                                targetDisplayName = [string]$child.displayName; targetDisplayVersion = [string]$child.displayVersion
                            })
                        $parent = $t.Apps[$appId]
                        $t.Relationships[[string]$r.targetId].Add([pscustomobject]@{
                                '@odata.type' = [string]$r.'@odata.type'; targetId = $appId; targetType = 'parent'
                                supersedenceType = [string]$r.supersedenceType
                                targetDisplayName = [string]$parent.displayName; targetDisplayVersion = [string]$parent.displayVersion
                            })
                    }
                    return $null
                }
            }
        }
    }
    $g = [regex]::Match($path, "^/groups\?\`$filter=displayName eq '([^']+)'")
    if ($g.Success -and $Method -eq 'GET') {
        $name = $g.Groups[1].Value.Replace("''", "'")
        return [pscustomobject]@{ value = @($t.Groups.Keys | Where-Object { $t.Groups[$_] -eq $name } | ForEach-Object { [pscustomobject]@{ id = $_; displayName = $name } }) }
    }
    $gid = [regex]::Match($path, '^/groups/([0-9a-fA-F-]{36})')
    if ($gid.Success -and $Method -eq 'GET') { return [pscustomobject]@{ id = $gid.Groups[1].Value; displayName = $t.Groups[$gid.Groups[1].Value] } }
    if ($path -eq '/groups' -and $Method -eq 'POST') {
        $id = Add-FakeGroup -Name ([string]$Body.displayName)
        return [pscustomobject]@{ id = $id; displayName = [string]$Body.displayName }
    }
    throw "fake graph: no route for $Method $Uri"
}
