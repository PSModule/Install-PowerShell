# Install-PowerShell

A cross‑platform GitHub Action that installs a specific **PowerShell Core** version—or the latest stable release—on any GitHub‑hosted runner
(Linux, macOS, or Windows). The action automatically skips installation when the requested version is already present.
Prerelease versions (e.g. `7.6.0-preview.6`, `7.5.0-rc.1`) are also supported.

## Usage

Add the action to a job in your workflow file:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install PowerShell
        uses: PSModule/install-powershell@v1
        with:
          Version: 7.5.0

      - name: Run a PowerShell script
        shell: pwsh
        run: |
          Write-Host "Using PowerShell $($PSVersionTable.PSVersion)"
```

### Installing a prerelease version

```yaml
      - name: Install PowerShell Preview
        uses: PSModule/install-powershell@v1
        with:
          Version: 7.6.0-preview.6
```

### Installing the latest prerelease

```yaml
      - name: Install latest PowerShell Preview
        uses: PSModule/install-powershell@v1
        with:
          Prerelease: true
```

### Using a custom token or anonymous API access

```yaml
      # Use a custom PAT to avoid rate limits
      - name: Install PowerShell (custom token)
        uses: PSModule/install-powershell@v1
        with:
          Token: ${{ secrets.MY_GITHUB_PAT }}

      # Use anonymous (unauthenticated) API access
      - name: Install PowerShell (anonymous)
        uses: PSModule/install-powershell@v1
        with:
          Token: ''
```

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `Version` | `false` | `latest` | Desired PowerShell Core version (e.g. `7.4.1`, `7.6.0-preview.6`). Use `latest` to install the newest stable release (or newest prerelease when `Prerelease` is `true`). |
| `Prerelease` | `false` | `false` | Install a prerelease version. When `true` and `Version` is `latest`, resolves to the latest prerelease. Similar to `-Prerelease` on `Install-PSResource`. |
| `Token` | `false` | `${{ github.token }}` | GitHub token used for API calls when resolving the `latest` version. Pass a custom PAT to avoid rate limits, or an empty string (`''`) to make fully unauthenticated (anonymous) API calls. |

## Secrets

This action does **not** require any secrets.
By default it authenticates to the GitHub API using the built-in `github.token`.
You can override this by setting the `Token` input to a custom PAT, or to an empty
string (`''`) for fully unauthenticated (anonymous) API access.

## Outputs

This action does **not** generate any outputs.

## How it works

* **Version resolution**
  If `Version` is set to `latest` (case‑insensitive), the action queries the GitHub API for the newest stable release tag in the
  `PowerShell/PowerShell` repository and substitutes that version. When `Prerelease` is `true`, it queries for the latest prerelease
  instead. Explicit prerelease version strings (e.g. `7.6.0-preview.6`) are passed through directly.

* **Skip logic**
  Before installing, the action checks the current runner to see whether the requested version is already available
  (`pwsh -Command $($PSVersionTable.PSVersion)`). If it matches, the step ends immediately.

* **Platform‑specific installers**

  | Runner OS | Install strategy |
  | --------- | ---------------- |
  | **Linux** (Debian/Ubuntu‑based) | Uses APT if available; otherwise downloads the `.deb` asset directly from the release page and installs with `dpkg`. |
  | **macOS** | Prefers Homebrew Cask (`brew install --cask powershell`) and falls back to downloading the `.pkg` installer. ARCH detection (`arm64` / `x64`) is automatic. |
  | **Windows** | Downloads the corresponding `.msi` package and installs silently with `msiexec`. |

* **Error handling**
  The step fails with a clear error message if the requested version cannot be resolved or if the operating‑system distribution is unsupported (e.g., non‑APT Linux distros).
