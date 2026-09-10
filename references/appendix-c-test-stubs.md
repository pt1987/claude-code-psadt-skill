# Appendix C: Test stub pattern

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix C: Test stub pattern

Before the launcher test on a DEV box, when the install action is too big/expensive:

```powershell
$orig = '<path-to-ps1>'
$test = "$env:TEMP\test-Invoke-AppDeployToolkit.ps1"
$content = [System.IO.File]::ReadAllText($orig)
$stub = '"STUB_REACHED_INSTALL" | Out-File $env:TEMP\stub-reached.log -Encoding utf8; exit 77'
$modified = $content -replace '& "\$\(\$adtSession\.DeploymentType\)-ADTDeployment"', $stub
[System.IO.File]::WriteAllText($test, $modified, [System.Text.UTF8Encoding]::new($true))

Start-Process powershell.exe -ArgumentList `
    '-ExecutionPolicy','Bypass','-NonInteractive','-NoProfile','-NoLogo',`
    '-Command', "try { & '$test' -DeploymentType Install -DeployMode Silent } catch { throw }; exit `$Global:LASTEXITCODE" `
    -Wait -NoNewWindow
Get-Content "$env:TEMP\stub-reached.log" -ErrorAction SilentlyContinue
```

- Exit 77 + stub log = init + session open OK, the bug sits in Install-ADTDeployment
- Exit 1 = parse/encoding bug, see 3.1
- Exit 60008 = Import-Module / Open-ADTSession bug, see A.2

---
