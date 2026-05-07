#!/usr/bin/env bash
# Fetches TVVLCKit.xcframework from VideoLAN's binary distribution and
# extracts it into Frameworks/. Run this once after cloning the repo.
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/cocoapods/prod/TVVLCKit-${VERSION}.tar.xz"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/Frameworks"
TMP="$(mktemp -d)"

if [ -d "${DEST_DIR}/TVVLCKit.xcframework" ]; then
    echo "TVVLCKit.xcframework already present at ${DEST_DIR}/TVVLCKit.xcframework — skipping."
    exit 0
fi

echo "Downloading TVVLCKit ${VERSION}…"
curl -fL --progress-bar "${URL}" -o "${TMP}/tvvlckit.tar.xz"

echo "Extracting…"
mkdir -p "${DEST_DIR}"
tar -xJf "${TMP}/tvvlckit.tar.xz" -C "${DEST_DIR}" --strip-components=1 \
    TVVLCKit-binary/TVVLCKit.xcframework

rm -rf "${TMP}"
echo "Done — TVVLCKit.xcframework installed to ${DEST_DIR}."
