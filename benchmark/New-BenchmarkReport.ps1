<#
.SYNOPSIS
    Turns the raw phase markers of the ten-application benchmark into BENCHMARK.md.

.DESCRIPTION
    Reads roster.json (which applications, which phases), bench.jsonl (the start/end markers written by
    bench.ps1) and results/<key>.json (one per finished application), then renders the Markdown report.

    A phase can be measured in several intervals. The logo and the dossier are both P8, but the dossier
    cannot be written before the sandbox verdict exists, and holding one bracket open across the whole VM
    run would charge P8 for six minutes of waiting it never did. All intervals of a phase are therefore
    added up, and the interval count is kept so that a split phase stays visible instead of hidden.

    Two totals exist per application and they answer different questions. "Phases added up" is the work.
    "End to end" is the first start to the last end, so it also contains the gaps between phases and it
    subtracts whatever ran in parallel. Phase 6 overlaps phases 7 and 8 by design, because packaging and
    the dossier do not need the test verdict, so end to end below the phase sum is the parallelism paying
    off rather than an error. Only end to end appears in the overview table; both appear per application.

    Durations are formatted with the invariant culture on purpose. On a German Windows the default would
    render 0.13 s as "0,13 s", which is wrong in an English document.

.PARAMETER BenchmarkRoot
    Folder holding roster.json, bench.jsonl and results/. Defaults to this script's folder.

.PARAMETER OutputPath
    Where BENCHMARK.md is written. Defaults to the repository root next to the benchmark folder.

.EXAMPLE
    pwsh benchmark/New-BenchmarkReport.ps1

.NOTES
    Author: psadt-deploy benchmark
    Changelog:
      - 1.0 (2026-09-18, Patrick Taubert): first version.
      - 1.1 (2026-09-18, Patrick Taubert): English output, invariant culture, overview table reduced to
        one total column after "Wall-Clock" turned out to mean nothing to a reader.
#>
[CmdletBinding()]
param(
    [string]$BenchmarkRoot = $PSScriptRoot,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$roster = Get-Content (Join-Path $BenchmarkRoot 'roster.json') -Raw | ConvertFrom-Json
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path $BenchmarkRoot -Parent) 'BENCHMARK.md' }

$events = @(
    Get-Content (Join-Path $BenchmarkRoot 'bench.jsonl') |
        Where-Object { $_.Trim() } |
        ForEach-Object { $_ | ConvertFrom-Json }
)

function Get-PhaseIntervals
{
    <#
    .SYNOPSIS
        Pairs the start/end markers of one application and phase, in timestamp order.
    .DESCRIPTION
        An unclosed start is reported rather than silently dropped. A missing end marker is exactly how
        the first version of the harness hid a bug: it wrote through a shell that did not exist on the
        PowerShell tool's PATH, and three markers vanished before anyone noticed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$Phase
    )

    $seq = @($Events | Where-Object { $_.app -eq $App -and $_.phase -eq $Phase } | Sort-Object ts)
    $intervals = [System.Collections.Generic.List[object]]::new()
    $open = $null

    foreach ($e in $seq)
    {
        if ($e.event -eq 'start')
        {
            $open = $e
            continue
        }
        if ($open)
        {
            $intervals.Add([pscustomobject]@{
                Start   = $open.ts
                End     = $e.ts
                Seconds = [math]::Round($e.ts - $open.ts, 2)
                Note    = $e.note
            })
            $open = $null
        }
    }

    $total = 0.0
    foreach ($i in $intervals) { $total += $i.Seconds }

    [pscustomobject]@{
        Intervals = $intervals
        Seconds   = [math]::Round($total, 2)
        Count     = $intervals.Count
        Unclosed  = [bool]$open
        Notes     = (@($intervals | ForEach-Object { $_.Note } | Where-Object { $_ }) -join ' | ')
    }
}

function Format-Duration
{
    <#
    .SYNOPSIS
        Renders a duration in seconds as the repository already writes them elsewhere.
    .DESCRIPTION
        Sub-second values keep two decimals, anything under a minute keeps one, above that it is m:ss.
        Invariant culture throughout, so a German host does not emit decimal commas into an English file.
        The minutes are floored, not rounded: [int] rounds in PowerShell, which once rendered 215.8 s as
        "4:35 min".
    #>
    param([double]$Seconds)

    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Seconds -lt 1) { return [string]::Format($ci, '{0:N2} s', $Seconds) }
    if ($Seconds -lt 60) { return [string]::Format($ci, '{0:N1} s', $Seconds) }

    $whole = [math]::Floor($Seconds)
    return [string]::Format($ci, '{0}:{1:00} min', [math]::Floor($whole / 60), ($whole % 60))
}

$phaseIds = @($roster.phases | ForEach-Object { $_.id })
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($app in @($roster.apps | Sort-Object no))
{
    $appEvents = @($events | Where-Object { $_.app -eq $app.key })
    if (-not $appEvents) { continue }

    $per = [ordered]@{}
    foreach ($id in $phaseIds) { $per[$id] = Get-PhaseIntervals -Events $events -App $app.key -Phase $id }

    $sum = 0.0
    foreach ($id in $phaseIds) { $sum += $per[$id].Seconds }

    $wall = [math]::Round(
        (($appEvents | Measure-Object -Property ts -Maximum).Maximum -
         ($appEvents | Measure-Object -Property ts -Minimum).Minimum), 2)

    # Package facts come from the per-application result file, which was taken straight from the manifest
    # (rule:manifest-is-truth). Nothing here is retyped by hand.
    $res = $null
    $resPath = Join-Path (Join-Path $BenchmarkRoot 'results') ($app.key + '.json')
    if (Test-Path -LiteralPath $resPath) { $res = Get-Content $resPath -Raw | ConvertFrom-Json }

    $rows.Add([pscustomobject]@{
        App        = $app
        Per        = $per
        Sum        = [math]::Round($sum, 2)
        Wall       = $wall
        Verdict    = $(if ($res -and $res.verdict) { [string]$res.verdict } else { 'n/a' })
        Scenarios  = $(if ($res -and $res.scenarios) { (@($res.scenarios) -join ', ') } else { '' })
        Version    = $(if ($res) { [string]$res.version } else { '' })
        ArtifactMb = $(if ($res -and $res.unencryptedSize) { [math]::Round($res.unencryptedSize / 1MB, 1) } else { $null })
    })
}

$md = [System.Collections.Generic.List[string]]::new()

# The count is DERIVED. It said "Ten applications" while a five-application run rendered under it -
# the same prose-versus-data drift the 2026-09-21 audit found in the README.
$appWord = switch ($rows.Count) { 1 { 'One application' } 2 { 'Two applications' } 3 { 'Three applications' }
    4 { 'Four applications' } 5 { 'Five applications' } 10 { 'Ten applications' } default { "$($rows.Count) applications" } }
$md.Add("# $appWord, measured end to end")
$md.Add('')
$md.Add('A run of ' + $roster.run.startedIso + " that packaged $($appWord.ToLower()) with this skill and timed every")
$md.Add('phase, from the first research call to the finished output files. The applications were packaged **one')
$md.Add('after another**, never in parallel, so the numbers stay comparable. Inside one application phase 6 runs')
$md.Add('alongside phases 7 and 8, which is what the skill prescribes: packaging and the dossier do not need the')
$md.Add('test verdict.')
$md.Add('')
$md.Add('| Condition | Value |')
$md.Add('|---|---|')
$md.Add('| Host | ' + $roster.run.host + ' |')
$md.Add('| Skill version | ' + $roster.run.skillVersion + ' |')
$md.Add('| PSAppDeployToolkit | ' + $roster.run.psadt + ' |')
$md.Add('| Phase 6 depth | ' + $roster.run.phase6 + ' |')
$md.Add('| Intune upload | ' + $(if ($roster.run.upload) { 'yes' } else { 'no, `decisions.upload = false` in every manifest' }) + ' |')
$md.Add('| Execution | ' + $(if ($roster.run.serial) { 'strictly serial, one application at a time' } else { 'parallel' }) + ' |')
$md.Add('')

$md.Add('## Results')
$md.Add('')
$md.Add('| # | Application | Version | Engine | Class | ' + ($phaseIds -join ' | ') + ' | End to end | Gate runs | Verdict |')
$md.Add('|---|---|---|---|---|' + (($phaseIds | ForEach-Object { '---:' }) -join '|') + '|---:|---:|---|')

foreach ($r in $rows)
{
    $cells = foreach ($id in $phaseIds)
    {
        if ($r.Per[$id].Count -eq 0) { '-' } else { Format-Duration $r.Per[$id].Seconds }
    }

    # How often phase 6 had to run. More than once means the gate rejected a package and the fix was
    # re-tested. It is the most load-bearing number here, because it separates "it passed" from "it
    # passed first time".
    $gateRuns = $r.Per['P6'].Count

    $md.Add('| ' + (@(
        $r.App.no
        $r.App.name
        $r.Version
        $r.App.engine
        ($r.App.tier + ' / ' + $r.App.sizeClass)
        ($cells -join ' | ')
        (Format-Duration $r.Wall)
        $(if ($gateRuns -gt 1) { '**' + $gateRuns + '**' } else { [string]$gateRuns })
        $r.Verdict
    ) -join ' | ') + ' |')
}

if ($rows.Count -gt 0)
{
    $wallAll = 0.0
    foreach ($r in $rows) { $wallAll += $r.Wall }
    $green = @($rows | Where-Object { $_.Verdict -eq 'GREEN' }).Count
    $firstTry = @($rows | Where-Object { $_.Verdict -eq 'GREEN' -and $_.Per['P6'].Count -le 1 }).Count
    $median = (Format-Duration (@($rows | ForEach-Object { $_.Wall } | Sort-Object)[[int]($rows.Count / 2)]))

    # Interpolation, not concatenation: an [int] on the left of '+' makes PowerShell try to parse the
    # string operand as a number, which fails on ' of '.
    $md.Add('')
    $md.Add("$green of $($rows.Count) applications passed the full sandbox gate, $firstTry of them on the first")
    $md.Add("attempt. Median $median per application, $(Format-Duration $wallAll) for the whole run.")
    $md.Add('')
    $md.Add('**Gate runs is the column to read first.** It counts how often phase 6 had to execute. Two runs means')
    $repeats = @($rows | Where-Object { $_.Per['P6'].Count -gt 1 } | ForEach-Object { $_.App.name })
    if ($repeats.Count) { $md.Add('The package(s) the gate sent back here: ' + ($repeats -join ', ') + '. What each rejection was is in `benchmark/FINDINGS.md`.') }
    else { $md.Add('No package needed a second gate run in this set.') }
}

$md.Add('')
$md.Add('### What each phase covers')
$md.Add('')
$md.Add('| ID | Phase | What is measured |')
$md.Add('|---|---|---|')
foreach ($p in $roster.phases) { $md.Add('| ' + $p.id + ' | ' + $p.label + ' | ' + $p.what + ' |') }

$md.Add('')
$md.Add('## How this was measured')
$md.Add('')
$md.Add('- `benchmark/bench.ps1` writes one marker per call, always inside the **same** PowerShell invocation as')
$md.Add('  the work it brackets. A separate tool round-trip between marker and work would leak one to two')
$md.Add('  seconds of harness latency into every phase boundary.')
$md.Add('- `start` sits at the end of the preceding call and `end` at the beginning of the next, so the thinking')
$md.Add('  time between two tool calls falls inside the measured window rather than into a gap.')
$md.Add('- **End to end** is the first start to the last end of an application. It contains the gaps between')
$md.Add('  phases and it subtracts whatever ran in parallel, so it can be lower than the phases added up. Both')
$md.Add('  numbers appear per application below.')
$md.Add('- A phase can consist of several intervals. P8 is the logo before the sandbox verdict and the dossier')
$md.Add('  after it; P6 is two intervals where the gate rejected the first attempt. Intervals are added up, not')
$md.Add('  stretched across the wait.')
$md.Add('- P1 is honest but not useful. The intake decision falls between two tool calls and measures fractions')
$md.Add('  of a second on most applications.')
$md.Add('- Application 1 was built twice. The first pass calibrated the harness and lost three markers, so 7-Zip')
$md.Add('  was re-measured with fresh research agents. Its research figure is the most optimistic in the table.')
$md.Add('- Raw data: `benchmark/bench.jsonl` holds every marker, `benchmark/results/` the package facts and')
$md.Add('  sandbox results per application. The `note` fields in the marker file were translated to English')
$md.Add('  after the run; timestamps were not touched.')
$md.Add('')

$md.Add('## Per application')
$md.Add('')
foreach ($r in $rows)
{
    $md.Add('### ' + $r.App.no + '. ' + $r.App.name + ' ' + $r.Version)
    $md.Add('')
    $head = 'Engine: ' + $r.App.engine + '. Class: ' + $r.App.tier + ' / ' + $r.App.sizeClass + '.'
    if ($r.ArtifactMb) { $head += ' Package content unencrypted: ' + $r.ArtifactMb + ' MB.' }
    $md.Add($head)
    $md.Add('')
    $md.Add('| Phase | Duration | Intervals | Note |')
    $md.Add('|---|---:|---:|---|')
    foreach ($p in $roster.phases)
    {
        $i = $r.Per[$p.id]
        if ($i.Count -eq 0) { continue }
        $md.Add('| ' + $p.id + ' ' + $p.label + ' | ' + (Format-Duration $i.Seconds) + ' | ' + $i.Count + ' | ' + $i.Notes + ' |')
    }
    $md.Add('| **Phases added up** | **' + (Format-Duration $r.Sum) + '** | | |')
    $md.Add('| **End to end** | **' + (Format-Duration $r.Wall) + '** | | first start to last end |')
    $md.Add('')
    if ($r.Scenarios)
    {
        $md.Add('Sandbox scenarios: ' + $r.Scenarios + '. Verdict **' + $r.Verdict + '**.')
        $md.Add('')
    }
}

Set-Content -LiteralPath $OutputPath -Value ($md -join "`n") -Encoding utf8
'BENCHMARK_OK: ' + $OutputPath + ' (' + $rows.Count + ' applications)'
