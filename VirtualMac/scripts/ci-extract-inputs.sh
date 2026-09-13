#!/bin/bash

# Extract the restore-image source files the build needs, processing one
# restore image at a time so a CI runner never has to hold every IPSW at once.
# This is the extraction half of scripts/prepare-inputs.sh without the
# macOS-only lipo/codesign assertions, intended for CI bring-up testing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IPSW="${VZ_IPSW_BIN:-$(command -v ipsw || true)}"
[[ -n "$IPSW" && -x "$IPSW" ]] ||
    die "ipsw tool not found; set VZ_IPSW_BIN to an ipsw binary"
DL="${VZ_DOWNLOAD_ROOT:-$VZ_BUILD_ROOT/downloads}"
MAC_OUT="$VZ_BUILD_ROOT/inputs/macos"
MACOS11_OUT="$VZ_BUILD_ROOT/inputs/macos11"
IPAD14_OUT="$VZ_BUILD_ROOT/inputs/ipados14"
mkdir -p "$DL" "$MAC_OUT" "$MACOS11_OUT" "$IPAD14_OUT"

MACOS_NAME="UniversalMac_13.2.1_22D68_Restore.ipsw"
BIG_SUR_NAME="UniversalMac_11.6_20G165_Restore.ipsw"
IPADOS14_NAME="iPad_Spring_2021_14.5_18E199_Restore.ipsw"
MACOS_URL="https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-48346/EFF99C1E-C408-4E7A-A448-12E1468AF06C/$MACOS_NAME"
BIG_SUR_URL="https://updates.cdn-apple.com/2021FallFCS/fullrestores/071-97388/C361BF5E-0E01-47E5-8D30-5990BC3C9E29/$BIG_SUR_NAME"
IPADOS14_URL="https://updates.cdn-apple.com/2021SpringFCS/fullrestores/071-17692/4BB409F6-D860-416B-A0EF-BDC941C74F3E/$IPADOS14_NAME"
MACOS_SHA256="0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04"
BIG_SUR_SHA256="9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6"
IPADOS14_SHA256="11023b65bc2f08eabbb141fa494873d41a1d4a43fca09904480d8e55e8065dc4"

download_verified() {
    local url="$1"
    local name="$2"
    local sha="$3"
    local dest="$DL/$name"
    if [[ -f "$dest" ]] &&
        echo "$sha  $dest" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "[extract] reusing verified $name"
    else
        echo "[extract] downloading $name"
        curl --fail --location --continue-at - --output "$dest" "$url"
    fi
    echo "$sha  $dest" | shasum -a 256 -c -
}

extract_macos() {
    local ipsw="$1" device="$2"
    echo "[extract] macOS dyld shared cache"
    "$IPSW" extract --dyld --dyld-arch arm64e --output "$MAC_OUT" "$ipsw"
    echo "[extract] macOS frameworks/resources, network helpers and kernelcache"
    "$IPSW" extract --files \
        --pattern '^(System/Library/Frameworks/(Hypervisor|ParavirtualizedGraphics|Virtualization)\.framework/Versions/A/(Resources/.*|XPCServices/.*)|System/Library/PrivateFrameworks/(MetalSerializer|DiskImages2)\.framework/Versions/A/Resources/.*|usr/libexec/(InternetSharing|bootpd)|usr/sbin/rtadvd|System/Library/LaunchDaemons/(com\.apple\.NetworkSharing\.plist|bootps\.plist))$' \
        --output "$MAC_OUT" "$ipsw"
    "$IPSW" extract --kernel --device "$device" --output "$MAC_OUT" "$ipsw"
}

extract_big_sur() {
    local ipsw="$1"
    echo "[extract] Big Sur dyld shared cache"
    "$IPSW" extract --dyld --dyld-arch arm64e --output "$MACOS11_OUT" "$ipsw"
    echo "[extract] Big Sur network helpers"
    "$IPSW" extract --files \
        --pattern '^(usr/libexec/InternetSharing|usr/sbin/rtadvd|System/Library/LaunchDaemons/(com\.apple\.NetworkSharing\.plist|bootps\.plist))$' \
        --output "$MACOS11_OUT" "$ipsw"
}

extract_ipados14() {
    local ipsw="$1"
    echo "[extract] iPadOS 14.5 bootpd"
    "$IPSW" extract --files --pattern '^usr/libexec/bootpd$' \
        --output "$IPAD14_OUT" "$ipsw"
}

# One image at a time: fetch, extract, then delete the IPSW to reclaim disk.
download_verified "$MACOS_URL" "$MACOS_NAME" "$MACOS_SHA256"
extract_macos "$DL/$MACOS_NAME" MacBookAir10,1
rm -f "$DL/$MACOS_NAME"

download_verified "$BIG_SUR_URL" "$BIG_SUR_NAME" "$BIG_SUR_SHA256"
extract_big_sur "$DL/$BIG_SUR_NAME"
rm -f "$DL/$BIG_SUR_NAME"

download_verified "$IPADOS14_URL" "$IPADOS14_NAME" "$IPADOS14_SHA256"
extract_ipados14 "$DL/$IPADOS14_NAME"
rm -f "$DL/$IPADOS14_NAME"

echo "[extract] inputs ready:"
du -sh "$VZ_BUILD_ROOT/inputs"
