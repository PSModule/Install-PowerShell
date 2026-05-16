[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RequestedVersion,

    [Parameter()]
    [string] $GitHubToken
)

function Get-GitHubApiHeaders {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Token
    )

    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers['Authorization'] = "Bearer $Token"
    }

    return $headers
}

function Resolve-ExpectedVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter()]
        [string] $Token
    )

    $resolvedVersion = $Version
    $normalizedVersion = $Version.Trim().ToLower()
    $headers = Get-GitHubApiHeaders -Token $Token

    if ($normalizedVersion -eq 'prerelease') {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=100' -Headers $headers
        $latestPrerelease = $releases | Where-Object { $_.prerelease -eq $true } | Select-Object -First 1

        if (-not $latestPrerelease) {
            throw 'No prerelease releases found for PowerShell/PowerShell.'
        }

        $resolvedVersion = $latestPrerelease.tag_name.TrimStart('v')
        Write-Host "Resolved 'prerelease' -> $resolvedVersion"
    } elseif ([string]::IsNullOrWhiteSpace($normalizedVersion) -or $normalizedVersion -in @('latest', 'null')) {
        $resolvedVersion = (
            Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers $headers
        ).tag_name.TrimStart('v')
        Write-Host "Resolved 'latest' -> $resolvedVersion"
    }

    return $resolvedVersion
}

$expectedVersion = Resolve-ExpectedVersion -Version $RequestedVersion -Token $GitHubToken

if ($IsWindows) {
    # On Windows, verify via the expected install directory to avoid stale PATH resolution.
    $isPrerelease = $expectedVersion -match '-'
    $majorVersion = ($expectedVersion -split '[\.-]')[0]
    $installDir = if ($isPrerelease) { "$majorVersion-preview" } else { $majorVersion }
    $pwshPath = "$env:ProgramFiles\PowerShell\$installDir\pwsh.exe"

    Write-Host "Windows: verifying via subprocess at $pwshPath"

    if (Test-Path $pwshPath) {
        $installedVersion = (& $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
    } else {
        Write-Host "Warning: Expected pwsh not found at $pwshPath, falling back to `$PSVersionTable"
        $installedVersion = ($PSVersionTable.PSVersion).ToString()
    }
} else {
    $installedVersion = ($PSVersionTable.PSVersion).ToString()
}

Write-Host "Installed PowerShell version: $installedVersion"
Write-Host "Expected  PowerShell version: $expectedVersion"

if ($installedVersion -ne $expectedVersion) {
    throw "Failed: expected $expectedVersion but got $installedVersion"
}

if ($RequestedVersion.Trim().ToLower() -eq 'prerelease' -and $installedVersion -notmatch '-') {
    throw "Prerelease validation failed: installed version '$installedVersion' does not contain a prerelease segment."
}
