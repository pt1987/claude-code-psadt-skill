<#
.SYNOPSIS
    Checks GitHub for a newer version of this skill and (optionally) updates the local copy in place.

.DESCRIPTION
    The "is there an update?" decision is made by COMMIT, not by the CHANGELOG version (which is only shown
    to the user as context). This avoids the raw-CDN cache lag and the chicken-and-egg of reading a version
    from a file that can't know about a newer one.

    WHAT COUNTS AS AN UPDATE DEPENDS ON WHAT THIS INSTALLATION TRACKS. Since the installer defaults to the
    newest release tag, most installations are pinned to a release, and comparing those against main would
    report them as permanently "behind" every time an unreleased commit lands. So:

      Track 'release' - the installation sits on a release tag (git: HEAD is exactly a tag; archive: the
        recorded `tooling.skillRef` looks like vX.Y.Z). An update exists when a NEWER RELEASE TAG exists.
        `Behind` is the number of releases in between, not the number of commits. Unreleased work on main
        is deliberately invisible here - that is what pinning means.
      Track 'branch' - the installation follows a branch (git: HEAD is on a branch; archive: the recorded
        ref is a branch, or nothing was recorded). Behaviour is as it always was:
          - git clone: `git fetch` then compare HEAD vs origin/<branch> (`UpdateAvailable` = behind > 0).
          - otherwise: the commits API sha, compared against `tooling.skillCommit` from config.json
            (unknown on first run -> offer to sync to latest).

    With -Apply (and only after the agent has asked the user) it updates the tracked skill files:
      - git clone   -> `git pull --ff-only origin <ref>`
      - otherwise   -> downloads the zip FOR THAT REF and overwrites SKILL.md, README.md, CHANGELOG.md,
                       LICENSE, SECURITY.md, package.json, references/, scripts/, tests/, bin/, then records
                       the applied commit and ref in the config.

.PARAMETER SkillRoot  Skill root (folder with SKILL.md/CHANGELOG.md). Defaults to the parent of this script.
.PARAMETER Repo       GitHub owner/repo. Default 'pt1987/claude-code-psadt-skill'.
.PARAMETER Branch     Branch to track when this installation follows a branch. Default 'main'.
.PARAMETER Ref        Force a specific ref (tag or branch) instead of detecting what is installed.
.PARAMETER Apply      Perform the update. Without it the script only checks (read-only).

.OUTPUTS
    PSCustomObject: LocalVersion, RemoteVersion, UpdateAvailable(bool), Behind(int|null), Method('git'|'archive'),
                    Track('release'|'branch'), LocalRef, RemoteRef, LocalCommit, RemoteCommit, Applied(bool),
                    WhatsNew(string), Action, Error
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Repo = 'pt1987/claude-code-psadt-skill',
    [string]$Branch = 'main',
    [string]$Ref,
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
function Get-ReleaseTags([string]$Repo, [hashtable]$Headers) {
    # Release tags, newest first. Sorted as [version], never as text: a string sort puts v0.9.0 above
    # v0.26.7. Returns @() on any failure so the caller can fall back to branch tracking.
    try {
        $tags = Invoke-RestMethod "https://api.github.com/repos/$Repo/tags?per_page=100" -Headers $Headers -ErrorAction Stop
    } catch { return @() }
    $out = foreach ($t in $tags) {
        if ($t.name -match '^v(\d+)\.(\d+)\.(\d+)$') {
            [pscustomobject]@{ Name = $t.name; Version = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"; Sha = $t.commit.sha }
        }
    }
    return @($out | Sort-Object Version -Descending)
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

# What does this installation follow - a release tag or a branch? Everything below depends on it, because
# an installation pinned to a release must not be told it is behind every time an unreleased commit lands
# on main. That is the whole point of pinning.
$localRef = $null
if ($Ref) {
    $localRef = $Ref
} elseif ($method -eq 'git') {
    # --exact-match: only a HEAD that IS a tag counts as pinned. A HEAD one commit past v0.26.7 is a
    # branch checkout that happens to be near a tag, and must keep branch semantics.
    $localRef = (& git -C $SkillRoot describe --tags --exact-match HEAD 2>$null)
    if ($localRef) { $localRef = "$localRef".Trim() }
} elseif ($cfg -and $cfg.tooling) {
    $localRef = [string]$cfg.tooling.skillRef
}
$track = if ($localRef -match '^v\d+\.\d+\.\d+$') { 'release' } else { 'branch' }
if ($track -eq 'branch' -and -not $localRef) { $localRef = $Branch }

$updateAvailable = $false; $remoteVersion = $null; $whatsNew = $null; $checkError = $null
$localCommit = $null; $remoteCommit = $null; $behind = $null; $remoteRef = $null
try {
    if ($track -eq 'release') {
        $tags = Get-ReleaseTags $Repo $ApiHeaders
        if (-not $tags -or $tags.Count -eq 0) { throw "no release tags readable for $Repo" }
        $newest = $tags[0]
        $remoteRef = $newest.Name
        $remoteCommit = $newest.Sha
        $localCommit = if ($method -eq 'git') { (& git -C $SkillRoot rev-parse HEAD).Trim() }
                       elseif ($cfg -and $cfg.tooling) { [string]$cfg.tooling.skillCommit } else { $null }
        $updateAvailable = $remoteRef -ne $localRef
        # Behind counts RELEASES, not commits: the position of the installed tag in the newest-first list
        # is exactly how many releases have shipped since. Unknown tag (hand-checkout, deleted tag) -> null.
        $idx = [array]::IndexOf([string[]]@($tags.Name), [string]$localRef)
        $behind = if ($idx -ge 0) { $idx } else { $null }
        try {
            $cont = Invoke-RestMethod "https://api.github.com/repos/$Repo/contents/CHANGELOG.md?ref=$remoteRef" -Headers $ApiHeaders -ErrorAction Stop
            $rt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cont.content))
            $remoteVersion = Get-TopChangelogVersion $rt; $whatsNew = Get-TopChangelogSection $rt
        } catch {}
    } elseif ($method -eq 'git') {
        $remoteRef = $Branch
        & git -C $SkillRoot fetch --quiet origin $Branch 2>$null
        $localCommit  = (& git -C $SkillRoot rev-parse HEAD).Trim()
        # A clone made by the installer is `--depth 1 --branch <tag>`, which configures a single-ref
        # fetch - so origin/<branch> does not exist even after fetching, and every git call below would
        # fail with "ambiguous argument". FETCH_HEAD is what the fetch just wrote, so use it as the
        # fallback rather than telling a pinned user their update check is broken.
        $remoteRev = "origin/$Branch"
        & git -C $SkillRoot rev-parse --verify --quiet $remoteRev 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $remoteRev = 'FETCH_HEAD' }
        $remoteCommit = (& git -C $SkillRoot rev-parse $remoteRev).Trim()
        $behind = [int]((& git -C $SkillRoot rev-list --count "HEAD..$remoteRev").Trim())
        $updateAvailable = $behind -gt 0
        try { $rt = (& git -C $SkillRoot show "${remoteRev}:CHANGELOG.md") -join "`n"; $remoteVersion = Get-TopChangelogVersion $rt; $whatsNew = Get-TopChangelogSection $rt } catch {}
    } else {
        $remoteRef = $Branch
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
    Behind = $behind; Method = $method; Track = $track; LocalRef = $localRef; RemoteRef = $remoteRef
    LocalCommit = $localCommit; RemoteCommit = $remoteCommit
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
        # Fetch tags too, or a release-tracked clone cannot resolve the tag it is being moved to.
        if ($track -eq 'release') { & git -C $SkillRoot fetch --quiet --tags origin 2>$null }
        $pull = & git -C $SkillRoot pull --ff-only origin $remoteRef 2>&1
        $result.Action = "git pull --ff-only origin ${remoteRef}: $($pull -join ' ')"
        $result.LocalCommit = (& git -C $SkillRoot rev-parse HEAD).Trim()
    } else {
        # refs/tags for a release, refs/heads for a branch. Getting this wrong is a 404, not a wrong
        # download: refs/heads/<tag> simply does not resolve.
        $zipRefPath = if ($track -eq 'release') { "refs/tags/$remoteRef" } else { "refs/heads/$Branch" }
        $zipUrl = "https://github.com/$Repo/archive/$zipRefPath.zip"
        $tmpZip = Join-Path ([IO.Path]::GetTempPath()) "psadt-skill-$($remoteRef -replace '[^A-Za-z0-9._-]', '_').zip"
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
        # Record the applied commit so the next check is an exact sha comparison (no version guessing),
        # and the ref so the next check knows whether this machine is release-pinned or on a branch.
        & (Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1') -SkillRoot $cfgProbe.Home -Updates @{ 'tooling.skillCommit' = $remoteCommit; 'tooling.skillVersion' = $remoteVersion; 'tooling.skillRef' = $remoteRef }
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
