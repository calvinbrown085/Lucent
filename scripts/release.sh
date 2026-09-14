#!/usr/bin/env bash
#
# End-to-end App Store release for Lucent: archive + upload (via
# scripts/testflight.sh), wait for processing, create the App Store version,
# write "What's New", attach the build and submit for review
# (via scripts/asc-release.swift). One build number is shared by every
# platform in the run.
#
#   scripts/release.sh [tvos|ios|all] --notes FILE [options]
#
#   --notes FILE       What's New text (required unless --check). If FILE
#                      contains a "== tvos" / "== ios" section header the
#                      matching section is used per platform; otherwise the
#                      whole file goes to every platform.
#   --build N          Reuse an already-uploaded build number (skips the
#                      archive/upload step).
#   --no-submit        Stop after attaching the build; submit by hand.
#   --check            Authenticate and print versions/builds, change nothing.
#   --dry-run          Print what would run.
#
# Auth: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH (API key with App Manager
# role — Developer can upload but cannot submit for review).
#
# After a successful submission the commit is tagged <platform>/v<version>
# (local only — push tags yourself). scripts/release-notes-draft.sh uses
# those tags to show what changed since the last release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Lucent/Lucent.xcodeproj"
OUT="$ROOT/build/testflight"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TARGETS="all"
NOTES=""
BUILD_NUMBER=""
SUBMIT=1
CHECK=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    tvos|ios|all) TARGETS="$1" ;;
    --notes) NOTES="$2"; shift ;;
    --build) BUILD_NUMBER="$2"; shift ;;
    --no-submit) SUBMIT=0 ;;
    --check) CHECK=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]] \
  || die "ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set — the App Store Connect API is required to submit"

if [[ "$CHECK" == 1 ]]; then
  exec swift "$ROOT/scripts/asc-release.swift" --check
fi

[[ -n "$NOTES" ]] || die "--notes FILE is required"
[[ -f "$NOTES" ]] || die "notes file not found: $NOTES"

MARKETING_VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed -E 's/.*= ([0-9.]+);/\1/')"
[[ -n "$MARKETING_VERSION" ]] || die "could not read MARKETING_VERSION from project.pbxproj"

if [[ -n "$(git -C "$ROOT" status --porcelain)" && "$DRY_RUN" == 0 ]]; then
  die "working tree has uncommitted changes — commit first so the release tag points at what shipped"
fi

UPLOAD=1
if [[ -n "$BUILD_NUMBER" ]]; then
  UPLOAD=0
else
  BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
fi

log "Lucent $MARKETING_VERSION ($BUILD_NUMBER) → $TARGETS  [submit=$SUBMIT upload=$UPLOAD]"

# Split a notes file into per-platform sections if it has "== tvos"/"== ios"
# headers; otherwise every platform gets the whole file.
notes_for() {
  local platform="$1" out="$OUT/release-notes-$platform.txt"
  mkdir -p "$OUT"
  if grep -qE '^== (tvos|ios)\s*$' "$NOTES"; then
    awk -v want="== $platform" '
      /^== (tvos|ios)[[:space:]]*$/ { on = ($0 == want); next }
      on { print }
    ' "$NOTES" > "$out"
  else
    cp "$NOTES" "$out"
  fi
  [[ -s "$out" ]] || die "no release notes for $platform in $NOTES"
  echo "$out"
}

tag_release() {
  local platform="$1" tag="$1/v$MARKETING_VERSION"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    log "Tag $tag already exists; leaving it"
  else
    git -C "$ROOT" tag -a "$tag" -m "Lucent $platform $MARKETING_VERSION ($BUILD_NUMBER)"
    log "Tagged $tag (not pushed)"
  fi
}

release_platform() {
  local platform="$1"                       # tvos | ios
  local asc_platform; asc_platform=$([[ "$platform" == tvos ]] && echo TV_OS || echo IOS)
  local notes_file; notes_file="$(notes_for "$platform")"

  local cmd=(swift "$ROOT/scripts/asc-release.swift"
    --platform "$asc_platform"
    --version "$MARKETING_VERSION"
    --build "$BUILD_NUMBER"
    --notes "$notes_file")
  [[ "$SUBMIT" == 1 ]] || cmd+=(--no-submit)

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '  %q' "${cmd[@]}"; echo
    return
  fi
  "${cmd[@]}"
  [[ "$SUBMIT" == 1 ]] && tag_release "$platform"
  return 0
}

# --- 1. archive + upload ------------------------------------------------------
if [[ "$UPLOAD" == 1 ]]; then
  upload_cmd=("$ROOT/scripts/testflight.sh" "$TARGETS" --build "$BUILD_NUMBER")
  [[ "$DRY_RUN" == 1 ]] && upload_cmd+=(--dry-run)
  "${upload_cmd[@]}"
else
  log "Reusing uploaded build $BUILD_NUMBER"
fi

# --- 2. version + notes + submit per platform ---------------------------------
case "$TARGETS" in
  tvos) release_platform tvos ;;
  ios)  release_platform ios ;;
  all)  release_platform tvos; release_platform ios ;;
esac

log "Done."
