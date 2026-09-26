<#
.SYNOPSIS  Shared include: replace a JSON store on disk atomically.
.DESCRIPTION
    Every JSON store in this skill is a read-modify-write: read the file, change one branch, write the
    whole thing back. Written with Set-Content that is a TRUNCATE followed by a write, and the window
    between them is where the file does not exist as valid JSON.

    That window is not theoretical here. SKILL.md Phase 6 tells the agent to run Phase 7 in the SAME turn
    as the sandbox gate, and both write <pkg>\psadt-package.json: the harness records results.systemTest
    and artifacts.logs while Invoke-PsadtPackage.ps1 records artifacts.intunewin. Two Claude sessions
    sharing one config home do the same to config.json and verified-switches.json.

    A half-written config.json is worse than a missing one: Get-PsadtConfig.ps1 reports it as "malformed"
    and every script downstream then behaves as if the skill had never been set up.

    So: serialise through a per-path mutex, write to a sibling temp file, and replace the target with it.
    On the same volume that is a metadata operation - a reader sees either the old file or the new one,
    never a truncated one.

    A failed replace THROWS. Until 0.49.1 the commit was Move-Item -Force, whose failure is a
    non-terminating error: no caller heard of it, the temp file was deleted and the update was gone.

.PARAMETER Path     The store to replace.
.PARAMETER Object   The object to serialise.
.PARAMETER Depth    ConvertTo-Json depth. The manifest nests arrays of objects; 12 is its documented floor.
.EXAMPLE
    . (Join-Path $PSScriptRoot '_JsonStore.ps1')
    Write-JsonAtomic -Path $manifestPath -Object $manifest -Depth 12
#>

function Write-JsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Object,
        [int]$Depth = 12
    )

    # Absolute before any .NET call: [System.IO.File] resolves a relative path against the process
    # directory, PowerShell against its own location, and the two are not the same.
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth $Depth

    # One mutex per store path. Global\ so it spans sessions, not just this process; the path is hashed
    # because a mutex name cannot contain a backslash and is capped at 260 characters.
    # SHA256.Create(), not [SHA256]::HashData: HashData exists only from .NET 5 on, so under Windows
    # PowerShell 5.1 every write threw - config.json from New-PsadtEntraApp.ps1 included, a script that
    # promises 5.1 and writes the config only after it has created the app and an undisplayed secret.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    $key = [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 32)
    $mutex = [System.Threading.Mutex]::new($false, "Global\psadt-jsonstore-$key")
    $held = $false
    try {
        # A writer that dies without releasing leaves the mutex abandoned; the next WaitOne throws
        # AbandonedMutexException and HANDS US THE LOCK. That is a recovered lock, not a failure.
        try { $held = $mutex.WaitOne(10000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }

        if (-not $held) {
            # Ten seconds is far longer than any write here takes. Rather than lose the update, say so and
            # write anyway - the temp+rename below still keeps a reader from ever seeing a partial file.
            Write-Verbose "Write-JsonAtomic: lock on $Path not acquired within 10s; replacing anyway."
        }

        $tmp = "$Path.$PID.tmp"
        try {
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
            # The commit point, and it must fail LOUDLY. File.Replace is atomic on the same volume and keeps
            # the original when it cannot replace it - held open by another process, a VM's mapped folder
            # among them. File.Move covers the first write. [NullString]::Value, because PowerShell turns
            # $null into '' for a string parameter and File.Replace refuses an empty backup path.
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
        }
        catch {
            throw "Write-JsonAtomic: $Path was NOT updated - $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
