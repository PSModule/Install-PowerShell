[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
param()

# Install-PowerShell
Write-Host "Requested version: [$env:REQUESTED_VERSION]"
Write-Host "Prerelease: [$env:PRERELEASE]"

if ($env:GH_HOST -ne 'github.com') {
    Write-Error "Unsupported GitHub host '$env:GH_HOST'. PowerShell releases are fetched from github.com."
    exit 1
}

# GitHub API headers used throughout the script
$headers = @{
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
if ($env:GITHUB_TOKEN) {
    $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
}
$apiBase = 'https://api.github.com'

# Resolve 'latest' -> concrete version
$req = $env:REQUESTED_VERSION
if ($req -and $req.Trim().ToLower() -eq 'latest') {
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

    $isDetectedPreview = $detected -match '-'
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

# Determine which package type is available for this release (MSI preferred, ZIP as fallback)
$msiName = "PowerShell-$($env:REQUESTED_VERSION)-win-x64.msi"
$zipName = "PowerShell-$($env:REQUESTED_VERSION)-win-x64.zip"
$baseUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$($env:REQUESTED_VERSION)"
$useMsi = $true

try {
    $releaseAssets = (Invoke-RestMethod -Uri "$apiBase/repos/PowerShell/PowerShell/releases/tags/v$($env:REQUESTED_VERSION)" -Headers $headers).assets
    $assetNames = $releaseAssets | Select-Object -ExpandProperty name
    if ($assetNames -notcontains $msiName) {
        if ($assetNames -contains $zipName) {
            $useMsi = $false
            Write-Host "Note: No MSI package found for this release; using ZIP instead."
        } else {
            Write-Host "Error: No suitable Windows x64 package (MSI or ZIP) found for PowerShell $($env:REQUESTED_VERSION)."
            exit 1
        }
    }
} catch {
    Write-Host "Warning: Could not query release assets; assuming MSI package is available."
}

$pkg = if ($useMsi) { $msiName } else { $zipName }
$url = "$baseUrl/$pkg"
Write-Host "Downloading from: $url"

$downloadSucceeded = $false
$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $null = Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing -ErrorAction Stop
        $downloadSucceeded = $true
        break
    } catch {
        if ($attempt -eq $maxAttempts) {
            throw
        }
        Write-Host "Warning: Download attempt $attempt failed; retrying..."
    }
}

if (-not $downloadSucceeded) {
    Write-Host 'Error: Failed to download PowerShell package after retry attempts.'
    exit 1
}

# Compute the install directory (used for both MSI and ZIP installs, and for GITHUB_PATH)
$isPrerelease = $env:REQUESTED_VERSION -match '-'
$majorVersion = ($env:REQUESTED_VERSION -split '[.\-]')[0]
if ($majorVersion -notmatch '^\d+$') {
    Write-Host "Warning: Computed major version ('$majorVersion') is invalid; skipping installation."
    exit 1
}
$installDir = if ($isPrerelease) {
    "$env:ProgramFiles\PowerShell\$majorVersion-preview"
} else {
    "$env:ProgramFiles\PowerShell\$majorVersion"
}

if ($useMsi) {
    # Install via MSI
    Write-Host "Starting installation of PowerShell [$($env:REQUESTED_VERSION)] from MSI..."
    $msiProcess = Start-Process msiexec.exe -ArgumentList '/i', $pkg, '/quiet', '/norestart' -Wait -PassThru
    if ($msiProcess.ExitCode -ne 0) {
        Write-Host "Error: Installation failed (exit code $($msiProcess.ExitCode))."
        exit 1
    }
} else {
    # Install via ZIP extraction
    Write-Host "Starting installation of PowerShell [$($env:REQUESTED_VERSION)] from ZIP..."
    $null = New-Item -ItemType Directory -Force -Path $installDir
    Expand-Archive -Path $pkg -DestinationPath $installDir -Force
}

Write-Host "Installation complete. PowerShell [$($env:REQUESTED_VERSION)] is now available."

# Add the install directory to GITHUB_PATH so subsequent `shell: pwsh` steps
# resolve to the version we just installed - even for preview builds whose
# install directory (7-preview) is not on the runner's default PATH.
if (Test-Path $installDir) {
    Write-Host "Adding install directory to GITHUB_PATH: $installDir"
    Add-Content -Path $env:GITHUB_PATH -Value $installDir
} else {
    Write-Host "Warning: Expected install directory not found: $installDir"
}
