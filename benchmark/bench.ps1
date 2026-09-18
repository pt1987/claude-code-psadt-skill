<#
.SYNOPSIS  Phase timer for the psadt-deploy 10-app benchmark.
.DESCRIPTION
  One marker per call, appended as JSON Lines to benchmark/bench.jsonl. Deliberately a .ps1
  invoked inside the SAME pwsh call as the work it brackets: a separate tool round-trip between
  marker and work would leak 1-2 s of harness latency into every phase boundary, and an earlier
  bash-based version simply did not exist on the PowerShell tool's PATH, which silently dropped
  three markers before anyone noticed. Start and end pay the same ~30 ms, so the delta is clean.
.EXAMPLE
  & .\bench.ps1 7zip P6 start
  & .\bench.ps1 7zip P6 end 'GREEN, 5 Szenarien'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][ValidateSet('start', 'end')][string]$Event,
    [string]$Note = ''
)
$ErrorActionPreference = 'Stop'
$now = [System.DateTimeOffset]::UtcNow
$rec = [pscustomobject]@{
    app   = $App
    phase = $Phase
    event = $Event
    ts    = [math]::Round($now.ToUnixTimeMilliseconds() / 1000, 3)
    iso   = $now.ToString('o')
    note  = $Note
}
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'bench.jsonl') -Value ($rec | ConvertTo-Json -Compress) -Encoding utf8
