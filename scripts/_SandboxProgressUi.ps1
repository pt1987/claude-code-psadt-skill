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

    This window does not depend on that console. It is a separate process with its own top-most form
    that polls a small JSON file the runner writes. If the console is missing, this is still there; if
    the console is present, this sits on top of it.

    It is intentionally read-only and passive: it never drives the run, and closing it does not stop
    anything. It is ASCII-only, like every script this skill writes, because the guest UI culture is
    whatever the base image has.
.PARAMETER ProgressFile
    JSON written by the runner: package, step, state, elapsed, timeout, detail, updated, verdict.
.PARAMETER TranscriptFile
    The guest transcript. Its tail is shown so the operator sees the same lines the host sees.
.NOTES
    Author: psadt-deploy
    Changelog:
      - 0.1 (2026-09-14, Patrick Taubert): first version. Guest-side progress that survives a missing console.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgressFile,
    [string]$TranscriptFile
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$bg = [System.Drawing.Color]::FromArgb(14, 18, 26)
$fg = [System.Drawing.Color]::FromArgb(228, 232, 240)
$accent = [System.Drawing.Color]::FromArgb(88, 180, 255)
$muted = [System.Drawing.Color]::FromArgb(140, 150, 165)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PSADT Sandbox Test - progress'
$form.ClientSize = New-Object System.Drawing.Size(860, 470)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(24, 24)
$form.TopMost = $true
$form.BackColor = $bg
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function New-Lbl {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Size, $Color, [string]$Text, [string]$Style = 'Regular')
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, [System.Drawing.FontStyle]::$Style)
    $l.ForeColor = $Color
    $l.BackColor = $bg
    $l.Text = $Text
    $form.Controls.Add($l)
    return $l
}

$lblPkg = New-Lbl 20 14 820 30 14 $fg 'starting...' 'Bold'
$lblState = New-Lbl 20 50 820 46 22 $accent '' 'Bold'
$lblTime = New-Lbl 20 102 820 26 11 $muted ''

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(20, 132)
$bar.Size = New-Object System.Drawing.Size(820, 16)
$bar.Style = 'Continuous'
$bar.Minimum = 0
$bar.Maximum = 100
$form.Controls.Add($bar)

$lblNote = New-Lbl 20 156 820 34 9 $muted ('Every deployment action runs as NT AUTHORITY\SYSTEM through a scheduled task and draws nothing on this desktop.' + [Environment]::NewLine + 'A moving timer below means the run is healthy. Closing this window does not stop the test.')

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(20, 196)
$log.Size = New-Object System.Drawing.Size(820, 250)
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BackColor = [System.Drawing.Color]::FromArgb(8, 11, 17)
$log.ForeColor = $fg
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.BorderStyle = 'FixedSingle'
$form.Controls.Add($log)

$script:lastTail = ''

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
        $p = $null
        if (Test-Path -LiteralPath $ProgressFile) {
            try { $p = Get-Content -LiteralPath $ProgressFile -Raw | ConvertFrom-Json } catch { $p = $null }
        }

        if (-not $p) {
            $lblPkg.Text = 'live transcript'
            $lblState.Text = 'waiting for the runner'
            $lblTime.Text = 'No progress file yet. The transcript below is live - if its last line keeps changing, the run is healthy.'
        }
        if ($p) {
            $lblPkg.Text = [string]$p.package
            $state = [string]$p.state
            $step = [string]$p.step

            if ($state -eq 'finished') {
                $v = [string]$p.verdict
                $lblState.Text = "FINISHED - $v"
                $lblState.ForeColor = if ($v -eq 'GREEN') { [System.Drawing.Color]::FromArgb(110, 220, 140) } else { [System.Drawing.Color]::FromArgb(255, 120, 120) }
                $lblTime.Text = "last update $($p.updated). This window stays open so the result can be read."
                $bar.Value = 100
                $timer.Stop()
            }
            else {
                $lblState.Text = "$step - $state"
                $elapsed = [int]$p.elapsed
                $timeout = [int]$p.timeout
                $lblTime.Text = if ($timeout -gt 0) {
                    "running {0}:{1:d2} of max {2}:{3:d2}   -   last update {4}" -f [int]($elapsed / 60), ($elapsed % 60), [int]($timeout / 60), ($timeout % 60), $p.updated
                }
                else { "last update $($p.updated)" }
                if ($timeout -gt 0) {
                    $pct = [int](100 * $elapsed / $timeout)
                    if ($pct -lt 0) { $pct = 0 }
                    if ($pct -gt 100) { $pct = 100 }
                    $bar.Value = $pct
                }
                if ($p.detail) { $lblPkg.Text = "$($p.package)   -   $($p.detail)" }
            }
        }

        if ($TranscriptFile -and (Test-Path -LiteralPath $TranscriptFile)) {
            $lines = Get-Content -LiteralPath $TranscriptFile -Tail 40
            $tail = ($lines -join [Environment]::NewLine)
            if ($tail -ne $script:lastTail) {
                $script:lastTail = $tail
                $log.Text = $tail
                $log.SelectionStart = $log.Text.Length
                $log.ScrollToCaret()
            }
        }
    })

$form.Add_Shown({
        $form.Activate()
        $timer.Start()
    })

[void]$form.ShowDialog()
