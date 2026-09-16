<#
.SYNOPSIS  An always-on-top progress window for the Windows Sandbox guest. Copied into the VM by Invoke-PsadtSandboxTest.ps1 and started by the runner.
.DESCRIPTION
    Every deployment action in the sandbox runs as NT AUTHORITY\SYSTEM through a scheduled task, and a
    SYSTEM task draws NOTHING on the interactive desktop. The runner's own console was meant to be the
    window an operator watches, but it cannot be relied on: under some Windows Sandbox builds the
    process started by <LogonCommand> gets no visible console window at all, and then a perfectly
    healthy 15-minute install is indistinguishable from a hang. Measured on 2026-09-14 while packaging
    Citrix Workspace: ten minutes in, the guest desktop showed nothing but wallpaper, and Task Manager
    listed no windowed PowerShell.

    This window does not depend on that console. It is a separate process with its own top-most window
    that polls a small JSON file the runner writes. If the console is missing, this is still there; if
    the console is present, this sits on top of it.

    WHY A SEPARATE PROCESS rather than a window the runner draws itself: the runner blocks for minutes
    inside schtasks waits, and anything painted from that thread is frozen for exactly the installs this
    window exists to make visible. Polling a file is the only arrangement in which a stuck action still
    repaints.

    WPF rather than WinForms since 0.31.0: the window shows EVERY phase at once with its exit code,
    duration, start/end, timeout, detection result and its own transcript, so an operator can see WHY a
    phase failed instead of only THAT the run is busy. Measured in the guest before the port: WPF loads
    there, renders at software tier (no vGPU) and paints the real XAML at 1180x800.

    It is intentionally read-only and passive: it never drives the run, and closing it does not stop
    anything. It is ASCII-only, like every script this skill writes, because the guest UI culture is
    whatever the base image has. The XAML beside it is ASCII too and draws its marks as XML entities.
.PARAMETER ProgressFile
    JSON written by the runner: package, step, state, elapsed, timeout, detail, updated, verdict, and
    phases[] - one record per phase with status, exitCode, seconds, started, ended, timeout, detection
    and logTail.
.PARAMETER TranscriptFile
    The guest transcript. Offered through "Open full log"; the per-phase transcripts come from the JSON.
.NOTES
    Author: psadt-deploy
    Changelog:
      - 0.1 (2026-09-14, Patrick Taubert): first version. Guest-side progress that survives a missing console.
      - 0.2 (2026-09-14, Patrick Taubert): WPF master/detail. Per-phase exit code, timings and transcript.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgressFile,
    [string]$TranscriptFile
)

$ErrorActionPreference = 'SilentlyContinue'

# Hide OUR OWN console, by handle. The launcher cannot use -WindowStyle Hidden for this: that lands in the
# child's STARTUPINFO and the FIRST window the process creates inherits it, which hid the progress window
# itself and left a live process with nothing on screen (measured 2026-09-14). Hiding the console
# explicitly touches only the console, and the WPF window that opens afterwards is unaffected.
try {
    Add-Type -Namespace PsadtSandboxUi -Name Win -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
    $ownConsole = [PsadtSandboxUi.Win]::GetConsoleWindow()
    if ($ownConsole -ne [System.IntPtr]::Zero) {
        [void][PsadtSandboxUi.Win]::ShowWindow($ownConsole, 0)   # SW_HIDE
    }
}
catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Read with an explicit encoding. Get-Content -Raw without -Encoding uses the ANSI codepage in Windows
# PowerShell 5.1, which mangles every non-ASCII byte - the exact trap App. B.1 describes, and the one
# that made the original draft of this window unusable.
$xamlPath = Join-Path $PSScriptRoot '_SandboxProgressUi.xaml'
$xamlText = [System.IO.File]::ReadAllText($xamlPath, (New-Object System.Text.UTF8Encoding($false)))
$win = [System.Windows.Markup.XamlReader]::Parse($xamlText)

$ui = @{}
foreach ($n in 'PackageName', 'Headline', 'HeadPill', 'HeadPillText', 'Elapsed', 'PhaseCount', 'PhaseTotal',
    'LastUpdate', 'FootNote', 'GroundNote', 'PhaseList', 'LogBox', 'TitleBar', 'BtnMin', 'BtnMax', 'BtnClose',
    'BtnCopy', 'BtnOpenLog', 'Track') {
    $ui[$n] = $win.FindName($n)
}

# --- window chrome (WindowStyle=None, so the title bar is ours) ---------------------------------------
$ui.TitleBar.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent,
    [System.Windows.Input.MouseButtonEventHandler] {
        param($s, $e)
        if ($e.ClickCount -eq 2) {
            $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        }
        else { $win.DragMove() }
    })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
# Closing this window does NOT stop the run: the runner is a different process and never looks here.
$ui.BtnClose.Add_Click({ $win.Close() })

$ui.BtnCopy.Add_Click({
        $sel = $ui.PhaseList.SelectedItem
        if ($sel) { Set-Clipboard -Value ([string]$sel.Log) }
    })
$ui.BtnOpenLog.Add_Click({
        if ($TranscriptFile -and (Test-Path -LiteralPath $TranscriptFile)) {
            Start-Process notepad.exe $TranscriptFile
        }
    })

# --- state --------------------------------------------------------------------------------------------
$script:lastRaw = ''
# The phase this code selected on its own. Anything else in the list box came from a click.
$script:autoSelected = ''

function Format-Clock {
    # $ZeroIsDash separates "no timeout configured" (a dash) from "zero seconds elapsed so far" (0:00).
    # Without it a phase that just started reads as having no clock at all.
    param([int]$Seconds, [switch]$ZeroIsDash)
    if ($Seconds -lt 0 -or ($Seconds -eq 0 -and $ZeroIsDash)) { return '-' }
    '{0}:{1:d2}' -f [int]($Seconds / 60), ($Seconds % 60)
}

function ConvertTo-PhaseItem {
    # The XAML compares Status against Pending/Running/Done/Failed and a WPF DataTrigger comparison is
    # CASE SENSITIVE. The JSON carries them lower case, so the titling happens here - the file stays the
    # machine-readable side and the presentation stays in the presentation layer.
    param($Phase)
    $status = switch ([string]$Phase.status) {
        'running' { 'Running' }
        'done' { 'Done' }
        'failed' { 'Failed' }
        default { 'Pending' }
    }
    $label = switch ($status) {
        'Running' { 'RUNNING' }
        'Done' { 'PASSED' }
        'Failed' { 'FAILED' }
        default { 'QUEUED' }
    }
    $exit = if ($null -ne $Phase.exitCode) { [string]$Phase.exitCode } else { '-' }
    $sub = switch ($status) {
        'Running' { 'running...' }
        'Done' { if ($null -ne $Phase.exitCode) { "exit $exit" } else { 'passed' } }
        'Failed' { if ($null -ne $Phase.exitCode) { "exit $exit" } else { 'failed' } }
        default { 'queued' }
    }
    [pscustomobject]@{
        Name         = [string]$Phase.name
        Status       = $status
        StatusLabel  = $label
        Sub          = $sub
        ExitCodeText = $exit
        DurationText = if ($null -ne $Phase.seconds) { "$($Phase.seconds) s" } else { '-' }
        Started      = if ($Phase.started) { [string]$Phase.started } else { '-' }
        Ended        = if ($Phase.ended) { [string]$Phase.ended } else { '-' }
        Timeout      = Format-Clock -Seconds ([int]$Phase.timeout) -ZeroIsDash
        Detection    = if ($Phase.detection) { [string]$Phase.detection } else { 'n/a' }
        Context      = 'NT AUTHORITY\SYSTEM - scheduled task'
        LogPath      = [string]$TranscriptFile
        Log          = (@($Phase.logTail) -join [Environment]::NewLine)
    }
}

# The clock, and only the clock, on every tick.
#
# Split out of Update-Ui because that function returns early when the progress file is byte-identical
# to the last read - correctly so, since rebuilding the phase list would reset the operator's
# selection and repaint for nothing. But the elapsed counter is the one element whose whole job is to
# keep moving: a frozen timer is how a healthy run looks like a hung one, which is the single question
# this window exists to answer.
#
# Whenever the file delivers a new (step, elapsed) pair, that is the truth and the baseline resets;
# between writes the display is extrapolated from this timer's own 1s tick. The reading can never
# drift more than one write interval from the runner, and it always moves. A finished run is left
# alone - Update-Ui puts 'done' there and nothing should tick over it.
function Update-ElapsedDisplay {
    param($p)
    if ([string]$p.state -eq 'finished') { return }

    $fileElapsed = [int]$p.elapsed
    $key = '{0}|{1}' -f [string]$p.step, $fileElapsed
    if ($script:elapsedKey -ne $key) {
        $script:elapsedKey = $key
        $script:elapsedBase = $fileElapsed
        $script:elapsedAt = Get-Date
    }
    $shown = $script:elapsedBase + [int]((Get-Date) - $script:elapsedAt).TotalSeconds

    $ui.Elapsed.Text = if ([int]$p.timeout -gt 0) {
        '{0} / {1}' -f (Format-Clock $shown), (Format-Clock ([int]$p.timeout))
    }
    else { Format-Clock $shown }
}

function Update-Ui {
    $raw = ''
    if (Test-Path -LiteralPath $ProgressFile) {
        $raw = [string](Get-Content -LiteralPath $ProgressFile -Raw -ErrorAction SilentlyContinue)
    }

    if (-not $raw) {
        $ui.PackageName.Text = 'waiting for the runner'
        $ui.Headline.Text = 'Starting'
        $ui.HeadPillText.Text = 'PREPARING THE GUEST'
        return
    }

    $p = $null
    try { $p = $raw | ConvertFrom-Json } catch { return }
    if (-not $p) { return }

    # Before the unchanged-guard below, so the clock keeps ticking through phases that write the file
    # rarely or not at all - GuestPrepare alone can sit there for 90 seconds.
    Update-ElapsedDisplay $p

    # Rebuilding the list on every tick would reset the selection and repaint for nothing. The runner
    # rewrites this file several times per action, but its CONTENT only changes when something happened.
    if ($raw -eq $script:lastRaw) {
        return
    }
    $script:lastRaw = $raw

    $phases = @($p.phases)
    if ($phases.Count -eq 0) { return }

    $selectedName = if ($ui.PhaseList.SelectedItem) { [string]$ui.PhaseList.SelectedItem.Name } else { '' }
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($ph in $phases) { $items.Add((ConvertTo-PhaseItem $ph)) }

    # ItemsSource is assigned DIRECTLY rather than through the window's DataContext. Measured here on
    # 2026-09-14: a PSCustomObject (and a Hashtable) as DataContext makes the ItemsSource binding report
    # UpdateTargetError and the list stays empty - WPF cannot read a property off a PSObject at that
    # level. Inside the item templates the same PSObjects bind correctly, which is why the rows, the
    # detail panel and the transcript all work; only this one hop has to be done in code.
    $ui.PhaseList.ItemsSource = $items
    $ui.Track.ItemsSource = $items

    $running = @($items | Where-Object { $_.Status -eq 'Running' })[0]
    $failed = @($items | Where-Object { $_.Status -eq 'Failed' })
    $settled = @($items | Where-Object { $_.Status -eq 'Done' -or $_.Status -eq 'Failed' })
    $doneCount = $settled.Count
    $finished = ([string]$p.state -eq 'finished')

    # Follow the run unless the operator has picked a phase to read; on the final update jump to the
    # first failure, which is the one they need and the one that scrolled out of the console long ago.
    #
    # "Picked" has to mean picked BY A PERSON. Comparing the selection against the last name this code
    # selected is the only way to tell the two apart - without that check the very first automatic
    # selection counts as a choice and the list stays on Elevation for the rest of the run, which is
    # exactly what it did.
    $userPicked = $selectedName -and $selectedName -ne $script:autoSelected
    $target = $null
    if ($finished -and $failed.Count) { $target = $failed[0] }
    elseif ($userPicked) { $target = @($items | Where-Object { $_.Name -eq $selectedName })[0] }
    if (-not $target) { $target = $running }
    if (-not $target -and $settled.Count) { $target = $settled[-1] }
    if (-not $userPicked -and $target) { $script:autoSelected = $target.Name }
    if ($target) {
        $ui.PhaseList.SelectedItem = $target
        # Selecting a row does NOT scroll to it. With 15 phases the list is taller than its viewport, so
        # from Uninstall onwards the running phase sat below the fold and the window looked stuck on the
        # pre-checks. Follow it down.
        $ui.PhaseList.ScrollIntoView($target)
    }

    $ui.PackageName.Text = [string]$p.package
    $ui.PhaseTotal.Text = [string]$items.Count
    $ui.PhaseCount.Text = '{0} / {1}' -f $doneCount, $items.Count
    $ui.LastUpdate.Text = if ($p.updated) { [string]$p.updated } else { (Get-Date).ToString('HH:mm:ss') }

    if ($finished) {
        $v = [string]$p.verdict
        $ui.Headline.Text = if ($failed.Count) { 'Run finished with failures' } else { 'All phases passed' }
        $ui.HeadPillText.Text = $v
        $ui.Elapsed.Text = 'done'
        $ui.FootNote.Text = '{0} passed, {1} failed' -f ($doneCount - $failed.Count), $failed.Count
        $ui.GroundNote.Text = if ($failed.Count) {
            'The run finished and the machine was cleaned up, but at least one phase failed. Pick the phase on the left to read its transcript, exit code and timings.'
        }
        else {
            'The full cycle completed as SYSTEM and the machine was returned to its baseline. Every phase carries its own exit code, duration and transcript.'
        }
        if ($failed.Count -or $v -ne 'GREEN') {
            $ui.HeadPill.Background = $win.FindResource('FailBg')
            $ui.HeadPill.BorderBrush = $win.FindResource('FailLine')
            $ui.HeadPillText.Foreground = $win.FindResource('FailFg')
        }
    }
    else {
        $ui.Headline.Text = if ($running) { $running.Name } else { [string]$p.step }
        $ui.HeadPillText.Text = 'RUNNING AS SYSTEM'
        $ui.FootNote.Text = '{0} of {1} phases complete' -f $doneCount, $items.Count
        # Elapsed is set by Update-ElapsedDisplay on every tick, above the unchanged-guard.
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Update-Ui })

$win.Topmost = $true

# The XAML asks for 1180x800 and centres itself. A sandbox desktop is whatever the host gives it, and a
# window larger than the work area is centred anyway - so it hangs off all four edges at once and the
# phase list and the buttons are the first things to go. Shrink to fit before it is ever shown; a
# slightly cramped window is readable, a clipped one is not.
$work = [System.Windows.SystemParameters]::WorkArea
$win.MinWidth = 0
$win.MinHeight = 0
if ($win.Width -gt ($work.Width - 24)) { $win.Width = [Math]::Max(640, $work.Width - 24) }
if ($win.Height -gt ($work.Height - 24)) { $win.Height = [Math]::Max(440, $work.Height - 24) }

# Position explicitly instead of trusting WindowStartupLocation. Measured in the guest on 2026-09-15:
# CenterScreen put the window at x=208 on a 1353-wide desktop, so its right-hand columns - TIMEOUT and
# DETECTION, the two a reader needs when a phase misbehaves - sat off the screen entirely. Centring
# inside the WORK AREA and clamping to its origin cannot place it outside the visible desktop.
$win.WindowStartupLocation = 'Manual'
$win.Left = $work.Left + [Math]::Max(0, ($work.Width - $win.Width) / 2)
$win.Top = $work.Top + [Math]::Max(0, ($work.Height - $win.Height) / 2)

$win.Add_SourceInitialized({ Update-Ui; $timer.Start() })
$win.Add_Closed({ $timer.Stop() })

[void]$win.ShowDialog()
