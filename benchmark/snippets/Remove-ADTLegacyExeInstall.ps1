function Remove-ADTLegacyExeInstall
{
    <#
    .SYNOPSIS
        Removes an EXE-installed predecessor that an MSI upgrade cannot see.

    .DESCRIPTION
        Windows Installer's RemoveExistingProducts only reaches products that Windows Installer itself
        registered. An instance that came from an NSIS, Inno Setup or other EXE setup is invisible to it,
        so the MSI installs beside it and the machine keeps two Add/Remove Programs entries pointing at
        one directory. Both 7-Zip and Notepad++ have documented reports of exactly this, Notepad++ with
        the extra twist that its own updater then reinstalls the EXE build over the MSI one.

        Only an EXE-registered instance is touched, identified by an UninstallString matching
        -UninstallerNamePattern. An MSI-registered instance is left alone, because the MSI upgrade handles
        that one correctly. Failures are logged and swallowed: a leftover legacy entry is untidy, not a
        reason to fail an otherwise good install.

        The silent switch of a vendor uninstaller is a CLAIM. A clean test guest has no EXE install to
        remove, so this path is not exercised by the sandbox gate.

    .PARAMETER UninstallKeyName
        Leaf name(s) of the Uninstall registry key to inspect, e.g. 'Notepad++'. Both the 64-bit and the
        WOW6432Node view are read for each name.

    .PARAMETER UninstallerNamePattern
        Regex the UninstallString must match for the entry to count as an EXE install.

    .PARAMETER SilentArgumentList
        Arguments handed to the vendor uninstaller for an unattended removal.

    .PARAMETER NsisSynchronous
        Appends NSIS's _?=<uninstaller directory> form. A bare Uninstall.exe /S copies itself to %TEMP%
        and RETURNS BEFORE THE REMOVAL HAS FINISHED, so the MSI that follows would start while the old
        files are still being deleted. _?= keeps the uninstaller in place and makes the call synchronous.
        It also stops the uninstaller from deleting itself, which is why the directory is cleaned up
        afterwards.

    .INPUTS
        None

    .OUTPUTS
        None

    .EXAMPLE
        Remove-ADTLegacyExeInstall -UninstallKeyName 'Notepad++' -SilentArgumentList '/S'

    .EXAMPLE
        Remove-ADTLegacyExeInstall -UninstallKeyName 'VLC media player' -NsisSynchronous
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$UninstallKeyName,

        [Parameter()]
        [string]$UninstallerNamePattern = 'uninstall.*\.exe',

        [Parameter()]
        [string[]]$SilentArgumentList = @('/S'),

        [Parameter()]
        [System.Management.Automation.SwitchParameter]$NsisSynchronous
    )

    begin
    {
        Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process
    {
        try
        {
            try
            {
                foreach ($name in $UninstallKeyName)
                {
                    $roots = @(
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$name"
                        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$name"
                    )

                    foreach ($root in $roots)
                    {
                        if (!(Test-Path -LiteralPath $root))
                        {
                            continue
                        }

                        $key = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
                        $uninstallString = [string]$key.UninstallString
                        if (!$uninstallString -or ($uninstallString -notmatch $UninstallerNamePattern))
                        {
                            continue
                        }

                        $exe = $uninstallString.Trim('"', ' ')
                        if (!(Test-Path -LiteralPath $exe))
                        {
                            Write-ADTLogEntry -Message "Legacy uninstall entry [$root] points at [$exe], which does not exist - skipping." -Severity 2
                            continue
                        }

                        $argList = @($SilentArgumentList)
                        $dir = [System.IO.Path]::GetDirectoryName($exe)
                        if ($NsisSynchronous)
                        {
                            # _?= must be the LAST argument and must not be quoted.
                            $argList += ('_?=' + $dir)
                        }

                        Write-ADTLogEntry -Message "Legacy EXE install found at [$exe] - removing it so the MSI does not leave a duplicate ARP entry."
                        Start-ADTProcess -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -IgnoreExitCodes '*'

                        if ($NsisSynchronous -and (Test-Path -LiteralPath $dir))
                        {
                            # _?= keeps the uninstaller in place, so it stays behind after a successful run.
                            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            catch
            {
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end
    {
        Complete-ADTFunction -Cmdlet $PSCmdlet
    }
}
