#!/usr/bin/env bash
#
# Archive Lucent for tvOS and/or iOS and upload to TestFlight.
#
#   scripts/testflight.sh [tvos|ios|all] [--build N] [--no-upload] [--dry-run]
#
# Defaults to `all`. Build number defaults to a UTC timestamp (yyyyMMddHHmm),
# which is always higher than the last one, so uploads never collide.
#
# Signing / upload credentials — pick one:
#   1. App Store Connect API key (recommended, works non-interactively):
#        export ASC_KEY_ID=ABC123DEFG
#        export ASC_ISSUER_ID=12345678-1234-1234-1234-123456789012
#        export ASC_KEY_PATH=~/.appstoreconnect/AuthKey_ABC123DEFG.p8
#   2. Nothing: xcodebuild uses the Apple ID signed into Xcode
#      (Xcode ▸ Settings ▸ Accounts) via -allowProvisioningUpdates.
#
# Requires: Xcode 26, Frameworks/ populated (scripts/fetch-*.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Lucent/Lucent.xcodeproj"
SCHEME="Lucent"
OUT="$ROOT/build/testflight"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TARGETS="all"
BUILD_NUMBER=""
UPLOAD=1
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    tvos|ios|all) TARGETS="$1" ;;
    --build) BUILD_NUMBER="$2"; shift ;;
    --no-upload) UPLOAD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -z "$BUILD_NUMBER" ]] && BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

log() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[[ -d "$DEVELOPER_DIR" ]] || die "Xcode not found at $DEVELOPER_DIR"
if [[ "$TARGETS" != "ios" && ! -d "$ROOT/Frameworks/TVVLCKit.xcframework" ]]; then
  die "Frameworks/TVVLCKit.xcframework missing — run scripts/fetch-tvvlckit.sh"
fi
if [[ "$TARGETS" != "tvos" && ! -d "$ROOT/Frameworks/MobileVLCKit.xcframework" ]]; then
  die "Frameworks/MobileVLCKit.xcframework missing — run scripts/fetch-mobilevlckit.sh"
fi

AUTH_ARGS=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  [[ -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]] || die "ASC_KEY_ID set but ASC_ISSUER_ID / ASC_KEY_PATH missing"
  [[ -f "$ASC_KEY_PATH" ]] || die "API key not found: $ASC_KEY_PATH"
  AUTH_ARGS=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  log "Using App Store Connect API key $ASC_KEY_ID"
else
  log "No ASC_KEY_ID set — relying on the Apple ID signed into Xcode"
fi

MARKETING_VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"
log "Lucent $MARKETING_VERSION ($BUILD_NUMBER) → $TARGETS"

if [[ "$UPLOAD" == 1 ]]; then
  EXPORT_DESTINATION="upload"
else
  EXPORT_DESTINATION="export"
fi

mkdir -p "$OUT"
EXPORT_PLIST="$OUT/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$EXPORT_DESTINATION</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>ZM4J56DC3Q</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

# --- one platform ----------------------------------------------------------
ship() {
  local platform="$1"       # tvOS | iOS
  local archive="$OUT/Lucent-$platform.xcarchive"
  local export_dir="$OUT/export-$platform"
  rm -rf "$archive" "$export_dir"

  log "Archiving $platform"
  local cmd=(
    xcodebuild archive
      -project "$PROJECT"
      -scheme "$SCHEME"
      -destination "generic/platform=$platform"
      -archivePath "$archive"
      -allowProvisioningUpdates
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}"
  )
  if [[ "$DRY_RUN" == 1 ]]; then printf '  %q' "${cmd[@]}"; echo; return; fi
  "${cmd[@]}" | tee "$OUT/archive-$platform.log" | grep -E "error:|warning: .*Lucent/Lucent|\*\* ARCHIVE" || true
  [[ -d "$archive" ]] || die "$platform archive failed — see $OUT/archive-$platform.log"

  log "Exporting $platform ($EXPORT_DESTINATION)"
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$export_dir" \
    -allowProvisioningUpdates \
    "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" \
    | tee "$OUT/export-$platform.log" | grep -E "error:|Upload|EXPORT|succeeded|Exported" || true
  if [[ "$UPLOAD" == 1 ]]; then
    grep -q "EXPORT SUCCEEDED" "$OUT/export-$platform.log" \
      || die "$platform upload failed — see $OUT/export-$platform.log"
    log "$platform build $BUILD_NUMBER uploaded. Processing takes ~10 min; it then appears under TestFlight in App Store Connect."
  else
    log "$platform .ipa exported to $export_dir"
  fi
}

case "$TARGETS" in
  tvos) ship tvOS ;;
  ios)  ship iOS ;;
  all)  ship tvOS; ship iOS ;;
esac

log "Done."
