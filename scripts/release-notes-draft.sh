#!/usr/bin/env bash
#
# Print the commits and changed files since the last release tag for a
# platform, as raw material for writing "What's New".
#
#   scripts/release-notes-draft.sh [tvos|ios] [--since REF]
#
# The base defaults to the newest <platform>/v* tag (created by
# scripts/release.sh). Files that only matter to the other platform are
# flagged so they can be left out of the notes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="tvos"
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    tvos|ios) PLATFORM="$1" ;;
    --since) SINCE="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$ROOT"
if [[ -z "$SINCE" ]]; then
  SINCE="$(git tag --list "$PLATFORM/v*" --sort=-v:refname | head -1)"
  [[ -n "$SINCE" ]] || { echo "no $PLATFORM/v* tag found; pass --since REF" >&2; exit 1; }
fi

VERSION="$(grep -m1 'MARKETING_VERSION' Lucent/Lucent.xcodeproj/project.pbxproj | sed -E 's/.*= ([0-9.]+);/\1/')"
echo "# Lucent $PLATFORM: changes since $SINCE (next version $VERSION)"
echo
echo "## Commits"
git log --reverse --format='- %h %s%n%w(0,4,4)%b' "$SINCE..HEAD"
echo
echo "## Files"
git diff --stat "$SINCE..HEAD" | sed 's/^/    /'
echo
if [[ "$PLATFORM" == tvos ]]; then
  echo "## iOS-only areas touched (usually omit from tvOS notes)"
  git diff --name-only "$SINCE..HEAD" \
    | grep -iE 'PIP|AudioSession|Docked|LayoutMetrics|Reminder' || echo "    (none)"
else
  echo "## tvOS-only areas touched (usually omit from iOS notes)"
  git diff --name-only "$SINCE..HEAD" \
    | grep -iE 'brandassets|TopShelf|MiniGuide' || echo "    (none)"
fi
