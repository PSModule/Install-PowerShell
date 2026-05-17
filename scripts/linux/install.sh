#!/usr/bin/env bash
# Install-PowerShell
set -e

echo "Requested version: [$REQUESTED_VERSION]"
echo "Prerelease: [$PRERELEASE]"

github_api_get() {
	local endpoint="$1"
	if command -v gh >/dev/null 2>&1 && [[ -n "$GH_TOKEN" ]]; then
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

# shellcheck disable=SC2016 # PowerShell expression is intentionally single-quoted for pwsh -Command.
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

# Determine Linux distribution type
ARCH=$(dpkg --print-architecture 2>/dev/null || rpm --eval '%{_arch}' 2>/dev/null || echo "x86_64")

# Query GitHub Releases API for the actual asset URLs to handle naming
# convention differences across releases (e.g. powershell-preview_ vs powershell_).
RELEASE_JSON=$(
	github_api_get "repos/PowerShell/PowerShell/releases/tags/v${REQUESTED_VERSION}"
)
if [[ -z "$RELEASE_JSON" ]]; then
	echo "Error: Failed to fetch release info for v${REQUESTED_VERSION} from GitHub."
	exit 1
fi

# Determine if the requested version is a prerelease (contains a hyphen, e.g. 7.6.0-preview.6)
IS_PRERELEASE=false
if [[ "$REQUESTED_VERSION" == *-* ]]; then
	IS_PRERELEASE=true
fi

if command -v apt-get >/dev/null || command -v dpkg >/dev/null; then
	# Debian/Ubuntu based
	echo "Detected Debian/Ubuntu based system..."
	if [[ "$IS_PRERELEASE" == "true" ]]; then
		# Prerelease .deb naming varies across releases:
		#   Older: powershell-preview_7.4.0-preview.5-1.deb_amd64.deb
		#   Newer: powershell_7.6.0-preview.6-1.deb_amd64.deb
		# Try powershell-preview_ first, then fall back to powershell_
		URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
			'[.assets[] | select(.name | test("^powershell-preview_.*\\.deb_" + $arch + "\\.deb$"))] | .[0].browser_download_url // empty')
		if [[ -z "$URL" ]]; then
			URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
				'[.assets[] | select(.name | test("^powershell_.*\\.deb_" + $arch + "\\.deb$"))] | .[0].browser_download_url // empty')
		fi
	else
		# For stable versions, select the powershell package (not powershell-lts or powershell-preview)
		URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
			'[.assets[] | select(.name | test("^powershell_.*\\.deb_" + $arch + "\\.deb$"))] | .[0].browser_download_url // empty')
	fi
	if [[ -z "$URL" ]]; then
		echo "Error: No .deb package found for architecture '$ARCH' in release v${REQUESTED_VERSION}."
		exit 1
	fi
	DEB_NAME=$(basename "$URL")
	echo "Downloading from: $URL"
	wget -q "$URL" -O "$DEB_NAME"

	# Remove all existing PowerShell packages to avoid dpkg conflicts
	# (powershell, powershell-lts, and powershell-preview all provide /usr/bin/pwsh)
	echo "Removing existing PowerShell packages to avoid conflicts..."
	sudo dpkg --remove powershell powershell-lts powershell-preview 2>/dev/null || true

	echo "Starting installation of PowerShell [$REQUESTED_VERSION]..."
	sudo dpkg -i "$DEB_NAME" || sudo apt-get -f install -y
elif command -v rpm >/dev/null; then
	# RHEL/Fedora/CentOS based
	echo "Detected RHEL/Fedora/CentOS based system..."
	if [[ "$IS_PRERELEASE" == "true" ]]; then
		# Prerelease .rpm naming varies across releases:
		#   Older: powershell-preview-7.4.0_preview.5-1.rh.x86_64.rpm
		#   Newer: powershell-7.6.0_preview.6-1.rh.x86_64.rpm
		# Try powershell-preview first, then fall back to powershell-<version>
		URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
			'[.assets[] | select(.name | test("^powershell-preview.*\\.rh\\." + (if $arch == "aarch64" then $arch else "x86_64" end) + "\\.rpm$"))] | .[0].browser_download_url // empty')
		if [[ -z "$URL" ]]; then
			URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
				'[.assets[] | select(.name | test("^powershell-[0-9].*\\.rh\\." + (if $arch == "aarch64" then $arch else "x86_64" end) + "\\.rpm$"))] | .[0].browser_download_url // empty')
		fi
	else
		URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" \
			'[.assets[] | select(.name | test("^powershell-[0-9].*\\.rh\\." + (if $arch == "aarch64" then $arch else "x86_64" end) + "\\.rpm$"))] | .[0].browser_download_url // empty')
	fi
	if [[ -z "$URL" ]]; then
		echo "Error: No .rpm package found for architecture '$ARCH' in release v${REQUESTED_VERSION}."
		exit 1
	fi
	RPM_NAME=$(basename "$URL")
	echo "Downloading from: $URL"
	wget -q "$URL" -O "$RPM_NAME"

	# Remove existing PowerShell packages to avoid conflicts
	echo "Removing existing PowerShell packages to avoid conflicts..."
	sudo rpm -e powershell powershell-preview 2>/dev/null || true

	echo "Starting installation of PowerShell [$REQUESTED_VERSION]..."
	sudo rpm -i "$RPM_NAME" || sudo yum install -y "$RPM_NAME"
else
	echo "Unsupported Linux distribution. Cannot determine package format."
	exit 1
fi

# Determine the install directory and add to PATH before verification.
# Preview builds install to /opt/microsoft/powershell/<major>-preview/
# which is not on the default PATH after removing the old powershell package.
MAJOR_VERSION=$(echo "$REQUESTED_VERSION" | cut -d'.' -f1)
if [[ "$IS_PRERELEASE" == "true" ]]; then
	INSTALL_DIR="/opt/microsoft/powershell/${MAJOR_VERSION}-preview"
else
	INSTALL_DIR="/opt/microsoft/powershell/${MAJOR_VERSION}"
fi
if [[ -d "$INSTALL_DIR" ]]; then
	export PATH="$INSTALL_DIR:$PATH"
fi

# Verify installation succeeded
# shellcheck disable=SC2016 # PowerShell expression is intentionally single-quoted for pwsh -Command.
INSTALLED_VERSION=$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)
if [[ "$INSTALLED_VERSION" != "$REQUESTED_VERSION" ]]; then
	echo "Error: Installation verification failed. Expected $REQUESTED_VERSION but got ${INSTALLED_VERSION:-nothing}."
	exit 1
fi
echo "Installation complete. PowerShell [$REQUESTED_VERSION] is now available."

# For prerelease builds, add the install directory to GITHUB_PATH so subsequent
# `shell: pwsh` steps resolve to the version we just installed.
if [[ "$IS_PRERELEASE" == "true" && -d "$INSTALL_DIR" ]]; then
	echo "Adding install directory to GITHUB_PATH: $INSTALL_DIR"
	echo "$INSTALL_DIR" >>"$GITHUB_PATH"
fi
