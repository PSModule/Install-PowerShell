# Install-PowerShell
Write-Host "Requested version: [$env:REQUESTED_VERSION]"
Write-Host "Prerelease: [$env:PRERELEASE]"

# Resolve 'latest' -> concrete version
$req = $env:REQUESTED_VERSION
if ($req -and $req.Trim().ToLower() -eq 'latest') {
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }
    $apiBase = if ($env:GH_HOST -and $env:GH_HOST -ne 'github.com') {
        "https://$($env:GH_HOST)/api/v3"
    } else {
        'https://api.github.com'
    }
    if ($env:PRERELEASE -eq 'true') {
        $releases = Invoke-RestMethod -Uri "$apiBase/repos/PowerShell/PowerShell/releases?per_page=100" -Headers $headers
        $latestRelease = $releases | Where-Object { $_.prerelease -eq $true } | Select-Object -First 1
        if (-not $latestRelease) {
            Write-Host 'Error: No prerelease PowerShell releases are available from GitHub.'
            exit 1
        }
        $latest = $latestRelease.tag_name.TrimStart('v')
        Write-Host "Latest prerelease PowerShell version detected: $latest"
    } else {
        $latest = (Invoke-RestMethod -Uri "$apiBase/repos/PowerShell/PowerShell/releases/latest" -Headers $headers).tag_name.TrimStart('v')
        if (-not $latest) {
            Write-Host 'Error: Failed to resolve latest stable PowerShell release from GitHub.'
            exit 1
        }
        Write-Host "Latest stable PowerShell release detected: $latest"
    }
    $env:REQUESTED_VERSION = $latest
} elseif ([string]::IsNullOrWhiteSpace($req)) {
    Write-Host "Error: Version input is required (or use 'latest')"
    exit 1
}

# Detect currently installed version (if any)
$detected = $null
try {
    $detected = (pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
    Write-Host "Currently installed PowerShell version: $detected"
} catch {
    Write-Host 'PowerShell is not currently installed'
}

if ($detected -eq $env:REQUESTED_VERSION) {
    Write-Host "PowerShell $detected already installed. Skipping."
    exit 0
}

# Downgrade detection
# Strip prerelease suffix for [version] comparison (e.g. '7.6.0-preview.6' -> '7.6.0')
$isDowngrade = $false
if ($detected -and $detected -ne $env:REQUESTED_VERSION) {
    try {
        $detectedBase = ($detected -split '-')[0]
        $requestedBase = ($env:REQUESTED_VERSION -split '-')[0]
        $detectedVersion = [version]$detectedBase
        $requestedVersion = [version]$requestedBase
        if ($detectedVersion -gt $requestedVersion) {
            Write-Host "Downgrade detected: $detected -> $($env:REQUESTED_VERSION)"
            $isDowngrade = $true
        } elseif ($detectedVersion -eq $requestedVersion -and $detected -ne $env:REQUESTED_VERSION) {
            # Same base version but different prerelease label - MSI installers cannot
            # handle cross-prerelease changes in-place, so force uninstall first.
            Write-Host "Prerelease version change detected (same base, different label): $detected -> $($env:REQUESTED_VERSION)"
            $isDowngrade = $true
        } else {
            Write-Host "Upgrade detected: $detected -> $($env:REQUESTED_VERSION)"
        }
    } catch {
        Write-Host 'Warning: Could not compare versions, proceeding with regular installation'
    }
}

# If downgrade -> fully uninstall current PowerShell 7
if ($isDowngrade) {
    Write-Host 'Uninstalling existing PowerShell version before downgrade...'

    # Search both 64-bit and 32-bit uninstall hives
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $isDetectedPreview = $detected -match '-preview|-rc'
    $pwshEntries = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Publisher -eq 'Microsoft Corporation' -and
            $_.DisplayName -like 'PowerShell 7*' -and
            $(if ($isDetectedPreview) { $_.DisplayName -like '*Preview*' } else { $_.DisplayName -notlike '*Preview*' }) -and
            $_.DisplayVersion -and
            ($_.DisplayVersion -match "^$([regex]::Escape(($detected -split '-')[0]))([.\-]|$)" -or $_.DisplayVersion -eq ($detected -split '-')[0])
        }

    $targetEntry = $pwshEntries | Select-Object -First 1
    if (-not $targetEntry) {
        Write-Host "Warning: Could not find an uninstall entry for PowerShell $detected"
    } else {
        $uninstallCmd = if ($targetEntry.QuietUninstallString) {
            $targetEntry.QuietUninstallString
        } else {
            $targetEntry.UninstallString
        }

        # If the uninstall command is MSI-based and lacks /quiet, add it
        if ($uninstallCmd -match 'msiexec') {
            if ($uninstallCmd -notmatch '/quiet') {
                $uninstallCmd += ' /quiet'
            }
            if ($uninstallCmd -notmatch '/norestart') {
                $uninstallCmd += ' /norestart'
            }
        }

        Write-Host "Running uninstall command:`n$uninstallCmd"
        $proc = Start-Process 'cmd.exe' -ArgumentList '/c', $uninstallCmd -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Host "Error: Uninstall failed (exit code $($proc.ExitCode))."
            exit 1
        }

        # Double-check removal
        try {
            $after = (pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
            if ($after) {
                Write-Host "Error: PowerShell is still present ($after) after uninstall. Aborting downgrade."
                exit 1
            }
        } catch {
        }
    }
}

# Download requested MSI
$msi = "PowerShell-$($env:REQUESTED_VERSION)-win-x64.msi"
$url = "https://github.com/PowerShell/PowerShell/releases/download/v$($env:REQUESTED_VERSION)/$msi"
Write-Host "Downloading from: $url"

$null = Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -ErrorAction Stop

# Install requested version
Write-Host "Starting installation of PowerShell [$($env:REQUESTED_VERSION)]..."
$msiProcess = Start-Process msiexec.exe -ArgumentList '/i', $msi, '/quiet', '/norestart' -Wait -PassThru
if ($msiProcess.ExitCode -ne 0) {
    Write-Host "Error: Installation failed (exit code $($msiProcess.ExitCode))."
    exit 1
}

Write-Host "Installation complete. PowerShell [$($env:REQUESTED_VERSION)] is now available."

# Add the install directory to GITHUB_PATH so subsequent `shell: pwsh` steps
# resolve to the version we just installed - even for preview builds whose
# install directory (7-preview) is not on the runner's default PATH.
$isPrerelease = $env:REQUESTED_VERSION -match '-'
$majorVersion = ($env:REQUESTED_VERSION -split '[.\-]')[0]
if ($majorVersion -match '^\d+$') {
    $installDir = if ($isPrerelease) {
        "$env:ProgramFiles\PowerShell\$majorVersion-preview"
    } else {
        "$env:ProgramFiles\PowerShell\$majorVersion"
    }
    if (Test-Path $installDir) {
        Write-Host "Adding install directory to GITHUB_PATH: $installDir"
        Add-Content -Path $env:GITHUB_PATH -Value $installDir
    } else {
        Write-Host "Warning: Expected install directory not found: $installDir"
    }
} else {
    Write-Host "Warning: Computed major version ('$majorVersion') is invalid; skipping GITHUB_PATH update."
}
