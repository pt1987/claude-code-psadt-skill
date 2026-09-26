<#
.SYNOPSIS
    The application identity that survives a version bump. Shared include; dot-source it, do not invoke.

.DESCRIPTION
    Every store this skill writes is keyed by the installer's SHA256 - deliberately, because a hash cannot
    go stale: the bytes it describes are immutable. The cost of that choice is that a new version of the
    same application misses every store by construction, and the knowledge recorded for the previous
    version becomes unreachable.

    This is the other half of the key. It is built from the identity the OPERATOR chose - app.vendor and
    app.name - and not from the binary's ProductName, for a measured reason. In a real 24-entry store:

      - six entries carry the version inside the product name ('LibreOffice 26.2.6.3',
        'PuTTY release 0.85 (64-bit)', 'Python 3.13.15 (64-bit)', '7-Zip 26.03 (x64 edition)', ...),
        so they can never match their own successor;
      - five are stored with PE-header padding ('WinSCP' followed by fifty spaces), so an exact
        comparison against a trimmed value fails too.

    app.vendor + app.name has neither problem: both Chrome package folders on the authoring machine -
    'GoogleChrome' and 'GoogleChrome_154.0.8037.58' - resolve to the same key, while the folder names do
    not.

    What this deliberately does NOT do is strip digits or version-looking fragments out of the name.
    'Office 2019' and 'Office 2021' are different products to the people deploying them, and a key that
    merged them would carry the wrong decisions forward silently. If a name carries a version, that is
    the operator's identity and it is theirs to change.
#>

function ConvertTo-PsadtAppKey {
    <#
        Vendor + name, normalised: trimmed, inner whitespace collapsed, lowercased.
        Returns '' when there is no name - never a key that would match every package.
    #>
    param(
        [string]$Vendor,
        [string]$Name
    )

    $n = if ($null -ne $Name) { ([string]$Name -replace '\s+', ' ').Trim() } else { '' }
    # No name, no identity. Returning something non-empty here (the vendor alone, say) would make every
    # app from that vendor look like the same application to the lookup.
    if ([string]::IsNullOrWhiteSpace($n)) { return '' }

    $v = if ($null -ne $Vendor) { ([string]$Vendor -replace '\s+', ' ').Trim() } else { '' }

    $key = if ($v) { "$v $n" } else { $n }
    return $key.ToLowerInvariant()
}

function Get-PsadtAppKeyFromManifest {
    <#
        The same key, taken from a parsed psadt-package.json. Returns '' for a manifest with no identity
        rather than throwing: callers use this to decide whether a lookup is even possible.
    #>
    param($Manifest)

    if ($null -eq $Manifest) { return '' }
    $app = $Manifest.app
    if ($null -eq $app) { return '' }
    return ConvertTo-PsadtAppKey -Vendor ([string]$app.vendor) -Name ([string]$app.name)
}
