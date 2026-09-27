<#
.SYNOPSIS  Shared include: read-modify-write a JSON store on disk, atomically and under one lock.
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

    Update-JsonAtomic is the read-modify-write, and the one to use. Until 0.49.2 every caller read the
    store BEFORE it asked for the lock, so two writers read the same old text and the second replace
    threw away the first one's change - atomically, so nothing ever looked broken. Update-JsonAtomic
    reads, hands the text to the caller's -Mutate block and replaces the file, all under one mutex, and
    it throws when it cannot get the lock instead of writing without it.

    Write-JsonAtomic replaces the whole store with an object the caller built outside the lock. It is
    kept for Set-PsadtVerifiedSwitch.ps1, whose read-merge-write still has to be restructured into a
    -Mutate block; every other store goes through Update-JsonAtomic.

.PARAMETER Path     The store to replace.
.PARAMETER Object   Write-JsonAtomic: the object to serialise.
.PARAMETER Mutate   Update-JsonAtomic: { param($rawText) ... } - receives the store's current text, or $null
                    when it does not exist yet, and returns EXACTLY ONE object to write. A throw leaves the
                    file untouched and reaches the caller unchanged. The block runs inside this function, so
                    a variable it reads by one of this function's parameter names ($Path, $Depth) resolves
                    to the function's value - give the caller's variables other names.
.PARAMETER Depth    ConvertTo-Json depth. The manifest nests arrays of objects; 12 is its documented floor.
.PARAMETER LockTimeoutSeconds
                    Update-JsonAtomic: how long to wait for another writer. On expiry it THROWS.
.EXAMPLE
    . (Join-Path $PSScriptRoot '_JsonStore.ps1')
    $manifest = Update-JsonAtomic -Path $manifestPath -Depth 12 -Mutate {
        param($rawText)
        $m = if ($null -ne $rawText) { $rawText | ConvertFrom-Json } else { [pscustomobject]@{ schema = 1 } }
        $m.app.version = '2.0'
        $m
    }
#>

function Get-JsonStoreMutex {
    param([Parameter(Mandatory)][string]$Path)
    # One mutex per store path. Global\ so it spans sessions, not just this process; the path is hashed
    # because a mutex name cannot contain a backslash and is capped at 260 characters.
    # SHA256.Create(), not [SHA256]::HashData: HashData exists only from .NET 5 on, so under Windows
    # PowerShell 5.1 every write threw - config.json from New-PsadtEntraApp.ps1 included, a script that
    # promises 5.1 and writes the config only after it has created the app and an undisplayed secret.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    $key = [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 32)
    return [System.Threading.Mutex]::new($false, "Global\psadt-jsonstore-$key")
}

function Invoke-JsonStoreRetry {
    # A reader that does not take the lock - Get-PsadtPackageManifest.ps1, a virus scanner - holds the file
    # for milliseconds, and File.Replace then fails with a sharing violation. Worth a few short retries;
    # a handle that stays (a VM's mapped folder) still ends in the throw.
    param([Parameter(Mandatory)][scriptblock]$Action, [int]$Attempts = 5, [int]$DelayMilliseconds = 200)
    for ($attempt = 1; ; $attempt++) {
        try { return (& $Action) }
        catch {
            $inner = $_.Exception
            while ($inner -is [System.Management.Automation.MethodInvocationException] -and $inner.InnerException) { $inner = $inner.InnerException }
            if ($inner -isnot [System.IO.IOException] -or $attempt -ge $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function Save-JsonStoreText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json, [string]$Caller = 'Write-JsonAtomic')
    # A unique temp name: $PID alone repeats across the runspaces of one process (thread jobs, Pester).
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $Json, [System.Text.UTF8Encoding]::new($false))
        # The commit point, and it must fail LOUDLY. File.Replace is atomic on the same volume and keeps
        # the original when it cannot replace it - held open by another process, a VM's mapped folder
        # among them. File.Move covers the first write. [NullString]::Value, because PowerShell turns
        # $null into '' for a string parameter and File.Replace refuses an empty backup path.
        Invoke-JsonStoreRetry {
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
        }
    }
    catch {
        throw "${Caller}: $Path was NOT updated - $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

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

    $mutex = Get-JsonStoreMutex -Path $Path
    $held = $false
    try {
        # A writer that dies without releasing leaves the mutex abandoned; the next WaitOne throws
        # AbandonedMutexException and HANDS US THE LOCK. That is a recovered lock, not a failure.
        try { $held = $mutex.WaitOne(10000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }

        if (-not $held) {
            # The caller read the store outside the lock anyway, so waiting longer cannot make this write
            # correct; the temp+replace below still keeps a reader from ever seeing a partial file.
            Write-Verbose "Write-JsonAtomic: lock on $Path not acquired within 10s; replacing anyway."
        }
        Save-JsonStoreText -Path $Path -Json $json -Caller 'Write-JsonAtomic'
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Update-JsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [int]$Depth = 12,
        [ValidateRange(1, 600)][int]$LockTimeoutSeconds = 30
    )

    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $storeDir = Split-Path -Parent $Path
    if ($storeDir -and -not (Test-Path -LiteralPath $storeDir)) {
        New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
    }

    $storeMutex = Get-JsonStoreMutex -Path $Path
    $storeHeld = $false
    try {
        try { $storeHeld = $storeMutex.WaitOne($LockTimeoutSeconds * 1000) }
        catch [System.Threading.AbandonedMutexException] { $storeHeld = $true }
        if (-not $storeHeld) {
            # Never write without the lock: the other writer read the same text, and whichever replace
            # lands second erases the first one's change.
            throw "Update-JsonAtomic: $Path was NOT updated - another writer held its lock for more than $LockTimeoutSeconds seconds. Nothing was written; run the step again."
        }

        $storeText = $null
        if ([System.IO.File]::Exists($Path)) {
            $storeText = Invoke-JsonStoreRetry { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
        }
        $storeOut = @(& $Mutate $storeText)
        if ($storeOut.Count -ne 1 -or $null -eq $storeOut[0]) {
            throw "Update-JsonAtomic: the -Mutate block must return exactly one object, it returned $($storeOut.Count). $Path was not changed."
        }
        Save-JsonStoreText -Path $Path -Json (ConvertTo-Json -InputObject $storeOut[0] -Depth $Depth) -Caller 'Update-JsonAtomic'
        return $storeOut[0]
    }
    finally {
        if ($storeHeld) { $storeMutex.ReleaseMutex() }
        $storeMutex.Dispose()
    }
}
