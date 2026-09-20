#!/bin/bash

# Local mirror of .github/workflows/build.yml. Fetches the dependency bundle
# published by the "Publish Dependencies" workflow, unpacks the build inputs,
# installs the toolchain, and produces build/release/*.deb.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export VZ_BUILD_ROOT="${VZ_BUILD_ROOT:-$REPO_ROOT/build}"

DEVICE_SUPPORT_NAME="DeviceSupport_macOS_27_beta.dmg"
DEVICE_SUPPORT_URL="https://github.com/nfzerox/DeviceSupportMirror/releases/download/1.0/DeviceSupport_macOS_27_beta.dmg"
DEVICE_SUPPORT_SHA256="d02e14429a02a78d8bf9d84df8ae55f5a03f2a00dbf58767f451b68eda417ca1"

REQUESTED_TAG="${1:-}"
DEPS_DIR=""
CLEANUP_DIRS=()

cleanup() {
    local status=$?
    local dir
    # bash 3.2 (macOS /bin/bash) treats an empty `"${arr[@]}"` as unbound
    # under `set -u`, which would mask the real failure in the EXIT trap.
    for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
        rm -rf "$dir"
    done
    # Preserve the script's exit status; otherwise the last cleanup command
    # (or an empty loop) would report success even after a failure.
    exit "$status"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./build.sh [command|dependencies-tag]

Builds the iPadOS package from a published dependency bundle.

Commands:
  (none)             Build the package
  install [ipaddr] [password]
                     Install the built .deb over SSH; password is used for
                     login and sudo, and falls back to VZ_IPAD_PASSWORD
  clean-deps         Remove the unpacked dependency bundle (build/inputs)
  -h, --help         Show this help

Arguments:
  dependencies-tag   Release tag to use (default: latest dependencies-*)

Environment:
  VZ_BUILD_ROOT      Generated files directory (default: ./build)
  VZ_IPAD_PASSWORD   SSH password (from .env or the environment)
  VZ_IPAD_USER       SSH user (default: mobile)
  VZ_IPAD_SSH_PORT   SSH port (default: 22)
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

clean_deps() {
    local inputs="$VZ_BUILD_ROOT/inputs"
    if [[ -e "$inputs" ]]; then
        echo "==> Removing downloaded dependencies at $inputs"
        du -sh "$inputs" 2>/dev/null || true
        rm -rf "$inputs"
        echo "removed $inputs"
    else
        echo "nothing to clean: $inputs does not exist"
    fi
}

install_package() {
    local host="${1:-}"
    local password="${2:-}"
    [[ -n "$host" ]] ||
        die "usage: ./build.sh install <ip-address> [password]"

    # The deployment credentials live in .env; load it lazily so the build and
    # clean-deps paths never depend on it.
    if [[ -f "$REPO_ROOT/.env" ]]; then
        set -a
        # shellcheck disable=SC1091
        source "$REPO_ROOT/.env"
        set +a
        VZ_BUILD_ROOT="${VZ_BUILD_ROOT:-$REPO_ROOT/build}"
    fi

    # An explicit argument overrides .env/the environment.
    if [[ -n "$password" ]]; then
        VZ_IPAD_PASSWORD="$password"
    fi
    [[ -n "${VZ_IPAD_PASSWORD:-}" ]] ||
        die "set VZ_IPAD_PASSWORD in .env or the environment, or pass it as the second argument"
    local user="${VZ_IPAD_USER:-mobile}"
    local port="${VZ_IPAD_SSH_PORT:-22}"

    need_command ssh
    need_command scp
    need_command sshpass

    local deb
    deb="$(ls -1t "$VZ_BUILD_ROOT"/release/VirtualMac_*.deb 2>/dev/null \
        | sed -n '1p' || true)"
    [[ -n "$deb" && -f "$deb" ]] ||
        die "package not found in $VZ_BUILD_ROOT/release; run ./build.sh first"

    # ssh and scp disagree on the port flag, so keep the shared options apart.
    local options=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )
    local target="$user@$host"
    local remote="/tmp/$(basename "$deb")"

    echo "==> Copying $(basename "$deb") to $target:$remote"
    # sshpass -e keeps the password out of the process table.
    SSHPASS="$VZ_IPAD_PASSWORD" sshpass -e scp "${options[@]}" -P "$port" \
        "$deb" "$target:$remote"

    echo "==> Installing on $host"
    if [[ "$user" == "root" ]]; then
        SSHPASS="$VZ_IPAD_PASSWORD" sshpass -e ssh "${options[@]}" -p "$port" \
            "$target" "dpkg -i '$remote' && rm -f '$remote'"
    else
        # Feed the password on stdin; sudo -S reads it without exposing it on
        # the remote command line.
        printf '%s\n' "$VZ_IPAD_PASSWORD" |
            SSHPASS="$VZ_IPAD_PASSWORD" sshpass -e ssh "${options[@]}" -p "$port" \
                "$target" \
                "sudo -S -p '' sh -c \"dpkg -i '$remote' && rm -f '$remote'\""
    fi

    echo "installed $(basename "$deb") on $host"
}

case "${REQUESTED_TAG:-}" in
    clean-deps) clean_deps; exit 0 ;;
    install) install_package "${2:-}" "${3:-}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
esac

need_command curl
need_command tar
need_command shasum

# Full history is required: the app's CFBundleVersion is the repository commit
# count, which build-ipad-deb.sh asserts against.
git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 ||
    die "not a git checkout"

if [[ -n "$(ls -A "$VZ_BUILD_ROOT/inputs" 2>/dev/null)" ]]; then
    echo "==> Build inputs already present in $VZ_BUILD_ROOT/inputs, skipping dependency download"
else
    need_command gh
    echo "==> Resolving dependencies release"
    if [[ -n "$REQUESTED_TAG" ]]; then
        TAG="$REQUESTED_TAG"
    else
        TAG="$(gh release list --limit 100 --json tagName,createdAt \
            -q '[.[] | select(.tagName | startswith("dependencies-"))] | sort_by(.createdAt) | reverse | .[0].tagName')"
    fi
    if [[ -z "$TAG" || "$TAG" == "null" ]]; then
        die "no dependencies release found"
    fi
    echo "using dependencies release: $TAG"

    echo "==> Downloading dependencies"
    DEPS_DIR="$(mktemp -d -t VirtualMac-deps.XXXXXX)"
    CLEANUP_DIRS+=("$DEPS_DIR")
    mkdir -p "$DEPS_DIR" "$VZ_BUILD_ROOT/inputs"
    gh release download "$TAG" -D "$DEPS_DIR"
    ls -lh "$DEPS_DIR"

    echo "==> Unpacking dependencies"
    (
        cd "$DEPS_DIR"

        # Reassemble any archive that was split into .part-* assets.
        : > bases.txt
        shopt -s nullglob
        for part in *.tar.xz.part-*; do
            printf '%s\n' "${part%.part-*}" >> bases.txt
        done
        if [[ -s bases.txt ]]; then
            sort -u bases.txt | while IFS= read -r base; do
                echo "merging $base"
                cat "$base".part-* > "$base"
                rm -f "$base".part-*
            done
        fi

        for archive in *.tar.xz; do
            echo "extracting $archive"
            tar -xf "$archive" -C "$VZ_BUILD_ROOT/inputs"
        done
    )
fi

echo "===== inputs size ====="
du -sh "$VZ_BUILD_ROOT/inputs"
find "$VZ_BUILD_ROOT/inputs" -type f | sort | head -100

# analyze-device-support.sh falls back to
# $VZ_BUILD_ROOT/downloads/DeviceSupport_macOS_27_beta.dmg, which
# build-ipad-installation.sh requires. Fetch the mirrored release and
# verify it against the digest pinned in setup.sh.
echo "==> Downloading DeviceSupport"
DEST="$VZ_BUILD_ROOT/downloads/$DEVICE_SUPPORT_NAME"
mkdir -p "$VZ_BUILD_ROOT/downloads"
curl --fail --location --continue-at - --output "$DEST" "$DEVICE_SUPPORT_URL"
actual="$(shasum -a 256 "$DEST" | awk '{print $1}')"
if [[ "$actual" != "$DEVICE_SUPPORT_SHA256" ]]; then
    die "DeviceSupport SHA-256 mismatch: expected $DEVICE_SUPPORT_SHA256, got $actual"
fi
ls -lh "$DEST"

echo "==> Installing build dependencies"
export HOMEBREW_NO_AUTO_UPDATE=1
brew bundle --file "$REPO_ROOT/VirtualMac/Brewfile" || \
    brew install dpkg gnu-tar go ldid-procursus libimobiledevice python rsync aria2

echo "==> Bootstrapping toolchain"
"$REPO_ROOT/VirtualMac/scripts/bootstrap.sh"

echo "==> Building package"
"$REPO_ROOT/VirtualMac/scripts/build-ipad-deb.sh"

echo "==> Report package"
df -h
ls -lh "$VZ_BUILD_ROOT/release" 2>/dev/null || true
