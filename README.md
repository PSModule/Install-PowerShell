# Install-PowerShell

A cross‑platform GitHub Action that installs a specific **PowerShell Core** version—or the latest stable release—on any GitHub‑hosted runner
(Linux, macOS, or Windows). The action automatically skips installation when the requested version is already present.

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

## Inputs

| Input   | Required | Default | Description |
| ------- | -------- | ------- | ----------- |
| `Version` | `false` | `latest` | Desired PowerShell Core version (e.g. `7.4.1`). Use `latest` to install the newest stable release. |

## Secrets

This action does **not** require any secrets.

## Outputs

This action does **not** generate any outputs.

## How it works

* **Version resolution**
  If `Version` is set to `latest` (case‑insensitive), the action queries the GitHub API for the newest stable release tag in the
  `PowerShell/PowerShell` repository and substitutes that version.

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
