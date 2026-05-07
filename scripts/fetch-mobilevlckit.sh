#!/usr/bin/env bash
# Fetches MobileVLCKit.xcframework from VideoLAN's binary distribution and
# extracts it into Frameworks/. Run this once after cloning the repo if you
# plan to build the iOS / iPadOS slice. Pinned to the same upstream build as
# scripts/fetch-tvvlckit.sh so the two VLCKit variants stay in sync.
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/cocoapods/prod/MobileVLCKit-${VERSION}.tar.xz"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/Frameworks"
TMP="$(mktemp -d)"

if [ -d "${DEST_DIR}/MobileVLCKit.xcframework" ]; then
    echo "MobileVLCKit.xcframework already present at ${DEST_DIR}/MobileVLCKit.xcframework — skipping."
    exit 0
fi

echo "Downloading MobileVLCKit ${VERSION}…"
curl -fL --progress-bar "${URL}" -o "${TMP}/mobilevlckit.tar.xz"

echo "Extracting…"
mkdir -p "${DEST_DIR}"
tar -xJf "${TMP}/mobilevlckit.tar.xz" -C "${DEST_DIR}" --strip-components=1 \
    MobileVLCKit-binary/MobileVLCKit.xcframework

rm -rf "${TMP}"
echo "Done — MobileVLCKit.xcframework installed to ${DEST_DIR}."
