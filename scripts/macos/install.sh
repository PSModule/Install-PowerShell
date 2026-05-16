#!/usr/bin/env bash
# Install-PowerShell
set -e

echo "Requested version: [$REQUESTED_VERSION]"
echo "Prerelease: [$PRERELEASE]"

github_api_get() {
  local endpoint="$1"
  if command -v gh >/dev/null 2>&1; then
    local gh_args=()
    if [[ -n "$GH_HOST" ]]; then
      gh_args+=(--hostname "$GH_HOST")
    fi
    gh api "${gh_args[@]}" -H "X-GitHub-Api-Version: 2022-11-28" "$endpoint"
    return
  fi

  local auth_header=()
  if [[ -n "$GITHUB_TOKEN" ]]; then
    auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  local api_base="https://api.github.com"
  if [[ -n "$GH_HOST" && "$GH_HOST" != "github.com" ]]; then
    api_base="https://${GH_HOST}/api/v3"
  fi

  curl -s -f \
    -H "Accept: application/vnd.github+json" \
    "${auth_header[@]}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_base}/${endpoint}"
}

# Only resolve to latest version if explicitly set to 'latest' (case-insensitive)
case "${REQUESTED_VERSION:-}" in
    [Ll][Aa][Tt][Ee][Ss][Tt])
        if [[ "$PRERELEASE" == "true" ]]; then
            REQUESTED_VERSION=$(
              github_api_get 'repos/PowerShell/PowerShell/releases?per_page=100' |
                jq -r '[.[] | select(.prerelease == true)] | (.[0].tag_name // empty)' | sed 's/^v//'
            )
            if [[ -z "$REQUESTED_VERSION" ]]; then
                echo "Error: No prerelease PowerShell releases found when resolving latest prerelease."
                exit 1
            fi
            echo "Latest prerelease PowerShell version detected: $REQUESTED_VERSION"
        else
            REQUESTED_VERSION=$(
              github_api_get 'repos/PowerShell/PowerShell/releases/latest' |
                jq -r '.tag_name' | sed 's/^v//'
            )
            if [[ -z "$REQUESTED_VERSION" ]]; then
                echo "Error: Failed to resolve latest stable PowerShell release from GitHub."
                exit 1
            fi
            echo "Latest stable PowerShell release detected: $REQUESTED_VERSION"
        fi
        ;;
    "")
        echo "Error: Version input is required (or use 'latest')"
        exit 1
        ;;
esac

DETECTED_VERSION=$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)
if [[ -n "$DETECTED_VERSION" ]]; then
  echo "Currently installed PowerShell version: $DETECTED_VERSION"
else
  echo "PowerShell is not currently installed"
fi

if [[ "$DETECTED_VERSION" == "$REQUESTED_VERSION" ]]; then
  echo "PowerShell $DETECTED_VERSION already installed. Skipping."
  exit 0
fi

# Determine architecture and download appropriate package
ARCH=$(uname -m)
case "$ARCH" in
  "arm64") PKG_NAME="powershell-${REQUESTED_VERSION}-osx-arm64.pkg" ;;
  *)       PKG_NAME="powershell-${REQUESTED_VERSION}-osx-x64.pkg" ;;
esac

URL="https://github.com/PowerShell/PowerShell/releases/download/v${REQUESTED_VERSION}/${PKG_NAME}"
echo "Downloading from: $URL"
echo "Starting installation of PowerShell [$REQUESTED_VERSION]..."

if ! curl -sSL "$URL" -o "$PKG_NAME"; then
  echo "Error: Failed to download PowerShell package"
  exit 1
fi
sudo installer -pkg "$PKG_NAME" -target /
echo "Installation complete. PowerShell [$REQUESTED_VERSION] is now available."

# For prerelease builds, add the install directory to GITHUB_PATH so subsequent
# `shell: pwsh` steps resolve to the version we just installed.
if [[ "$REQUESTED_VERSION" == *-* ]]; then
  MAJOR_VERSION=$(echo "$REQUESTED_VERSION" | cut -d'.' -f1)
  if [[ "$MAJOR_VERSION" =~ ^[0-9]+$ ]]; then
    INSTALL_DIR="/usr/local/microsoft/powershell/${MAJOR_VERSION}-preview"
    if [[ -d "$INSTALL_DIR" ]]; then
      echo "Adding install directory to GITHUB_PATH: $INSTALL_DIR"
      echo "$INSTALL_DIR" >> "$GITHUB_PATH"
    fi
  else
    echo "Warning: Computed MAJOR_VERSION ('$MAJOR_VERSION') is invalid; skipping GITHUB_PATH update." >&2
  fi
fi
