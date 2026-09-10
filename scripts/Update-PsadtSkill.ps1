<#
.SYNOPSIS
    Checks GitHub for a newer version of this skill and (optionally) updates the local copy in place.

.DESCRIPTION
    The "is there an update?" decision is made by COMMIT, not by the CHANGELOG version (which is only shown
    to the user as context). This avoids the raw-CDN cache lag and the chicken-and-egg of reading a version
    from a file that can't know about a newer one.
      - git clone (.git present): `git fetch` then compare HEAD vs origin/<branch> (`UpdateAvailable` = behind > 0).
      - otherwise: GitHub commits API gives the latest commit sha; compared against `tooling.skillCommit`
        stored in config.json on the last update (unknown on first run -> offer to sync to latest).

    With -Apply (and only after the agent has asked the user) it updates the tracked skill files:
      - git clone   -> `git pull --ff-only`
      - otherwise   -> downloads the branch zip and overwrites SKILL.md, README.md, CHANGELOG.md, LICENSE,
                       package.json, references/, scripts/, tests/, bin/ and records the applied commit in the config.

.PARAMETER SkillRoot  Skill root (folder with SKILL.md/CHANGELOG.md). Defaults to the parent of this script.
.PARAMETER Repo       GitHub owner/repo. Default 'pt1987/claude-code-psadt-skill'.
.PARAMETER Branch     Branch to track. Default 'main'.
.PARAMETER Apply      Perform the update. Without it the script only checks (read-only).

.OUTPUTS
    PSCustomObject: LocalVersion, RemoteVersion, UpdateAvailable(bool), Behind(int|null), Method('git'|'archive'),
                    LocalCommit, RemoteCommit, Applied(bool), WhatsNew(string), Action, Error
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Repo = 'pt1987/claude-code-psadt-skill',
    [string]$Branch = 'main',
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

# Tracked content an update may overwrite. Everything else (config.json, secret.dpapi, tools/, docs/, .git)
# is machine-local / gitignored and is deliberately preserved.
$TrackedItems = @('SKILL.md', 'README.md', 'CHANGELOG.md', 'LICENSE', 'SECURITY.md', 'package.json', 'references', 'scripts', 'tests', 'bin')
$ApiHeaders = @{ 'User-Agent' = 'psadt-deploy-skill'; 'Accept' = 'application/vnd.github+json' }

function Get-TopChangelogVersion([string]$text) {
    foreach ($line in ($text -split "`n")) { if ($line -match '^\s*##\s+(\d+\.\d+\.\d+)') { return $Matches[1] } }
    return $null
}
function Get-TopChangelogSection([string]$text) {
    $out = @(); $started = $false
    foreach ($line in ($text -split "`n")) {
        if ($line -match '^\s*##\s+\d+\.\d+\.\d+') { if ($started) { break }; $started = $true }
        if ($started) { $out += $line }
    }
    return ($out -join "`n").Trim()
}

$localChangelog = Join-Path $SkillRoot 'CHANGELOG.md'
$localVersion = if (Test-Path $localChangelog) { Get-TopChangelogVersion (Get-Content $localChangelog -Raw) } else { $null }
# $SkillRoot is the skill TREE (SKILL.md / CHANGELOG.md / .git). The recorded commit lives in the config,
# which may still sit in that tree (pre-0.19) or in the config home - resolve it instead of assuming.
$cfgProbe = if (Test-Path (Join-Path $SkillRoot 'config.json')) {
    & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
} else {
    & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')
}
$cfg = $cfgProbe.Config

$isGit  = Test-Path (Join-Path $SkillRoot '.git')
$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$method = if ($isGit -and $hasGit) { 'git' } else { 'archive' }

$updateAvailable = $false; $remoteVersion = $null; $whatsNew = $null; $checkError = $null
$localCommit = $null; $remoteCommit = $null; $behind = $null
try {
    if ($method -eq 'git') {
        & git -C $SkillRoot fetch --quiet origin $Branch 2>$null
        $localCommit  = (& git -C $SkillRoot rev-parse HEAD).Trim()
        $remoteCommit = (& git -C $SkillRoot rev-parse "origin/$Branch").Trim()
        $behind = [int]((& git -C $SkillRoot rev-list --count "HEAD..origin/$Branch").Trim())
        $updateAvailable = $behind -gt 0
        try { $rt = (& git -C $SkillRoot show "origin/${Branch}:CHANGELOG.md") -join "`n"; $remoteVersion = Get-TopChangelogVersion $rt; $whatsNew = Get-TopChangelogSection $rt } catch {}
    } else {
        $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -Headers $ApiHeaders -ErrorAction Stop
        $remoteCommit = $commit.sha
        $localCommit  = if ($cfg -and $cfg.tooling) { [string]$cfg.tooling.skillCommit } else { $null }
        $updateAvailable = if ($localCommit) { $localCommit -ne $remoteCommit } else { $true }   # unknown -> offer sync
        try {
            $cont = Invoke-RestMethod "https://api.github.com/repos/$Repo/contents/CHANGELOG.md?ref=$Branch" -Headers $ApiHeaders -ErrorAction Stop
            $rt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cont.content))
            $remoteVersion = Get-TopChangelogVersion $rt; $whatsNew = Get-TopChangelogSection $rt
        } catch {}
    }
} catch { $checkError = "Could not reach GitHub: $($_.Exception.Message)" }

$result = [ordered]@{
    LocalVersion = $localVersion; RemoteVersion = $remoteVersion; UpdateAvailable = [bool]$updateAvailable
    Behind = $behind; Method = $method; LocalCommit = $localCommit; RemoteCommit = $remoteCommit
    Applied = $false; WhatsNew = $whatsNew; Action = 'Checked'; Error = $checkError
}

if (-not $Apply -or -not $updateAvailable) {
    if ($checkError) { $result.Action = 'CheckFailed' }
    elseif (-not $updateAvailable) { $result.Action = 'UpToDate' }
    return [pscustomobject]$result
}

# --- Apply -----------------------------------------------------------------------------------------
try {
    if ($method -eq 'git') {
        $pull = & git -C $SkillRoot pull --ff-only origin $Branch 2>&1
        $result.Action = "git pull --ff-only: $($pull -join ' ')"
        $result.LocalCommit = (& git -C $SkillRoot rev-parse HEAD).Trim()
    } else {
        $zipUrl = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
        $tmpZip = Join-Path ([IO.Path]::GetTempPath()) "psadt-skill-$Branch.zip"
        $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "psadt-skill-extract"
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        Expand-Archive $tmpZip -DestinationPath $tmpDir -Force
        $extracted = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
        if (-not $extracted) { throw "Downloaded archive had no content folder." }
        foreach ($item in $TrackedItems) {
            $src = Join-Path $extracted.FullName $item
            if (-not (Test-Path $src)) { continue }
            if ((Get-Item $src) -is [IO.DirectoryInfo]) { Copy-Item $src $SkillRoot -Recurse -Force }
            else { Copy-Item $src (Join-Path $SkillRoot $item) -Force }
        }
        Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        # Record the applied commit so the next check is an exact sha comparison (no version guessing).
        & (Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1') -SkillRoot $cfgProbe.Home -Updates @{ 'tooling.skillCommit' = $remoteCommit; 'tooling.skillVersion' = $remoteVersion }
        $result.Action = "archive: synced tracked files to $($remoteCommit.Substring(0, [Math]::Min(7, $remoteCommit.Length))) (config/secret/tools preserved)"
        $result.LocalCommit = $remoteCommit
    }
    if (Test-Path $localChangelog) { $result.LocalVersion = Get-TopChangelogVersion (Get-Content $localChangelog -Raw) }
    $result.Applied = $true
} catch {
    # Clean up the archive temp files on failure too (the success path above already removes them).
    if ($tmpZip -or $tmpDir) { Remove-Item @($tmpZip, $tmpDir | Where-Object { $_ }) -Recurse -Force -ErrorAction SilentlyContinue }
    $result.Action = 'UpdateFailed'; $result.Error = "$_"
}
[pscustomobject]$result
