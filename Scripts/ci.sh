#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DESTINATION:-}" ]]; then
  SIMULATOR_ID="$(
    xcrun simctl list devices available |
      awk '/\(Booted\)/ { for (i = 1; i <= NF; i++) if ($i ~ /^\([0-9A-F-]{36}\)$/) { gsub(/[()]/, "", $i); print $i; exit } }'
  )"

  if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID="$(
      xcrun simctl list devices available |
        awk '/iPhone/ { for (i = 1; i <= NF; i++) if ($i ~ /^\([0-9A-F-]{36}\)$/) { gsub(/[()]/, "", $i); print $i; exit } }'
    )"
  fi

  if [[ -z "$SIMULATOR_ID" ]]; then
    echo "No available iOS simulator found. Set DESTINATION explicitly." >&2
    exit 1
  fi

  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

xcodegen generate
xcodebuild \
  -project OfflineReader.xcodeproj \
  -scheme OfflineReader \
  -destination "$DESTINATION" \
  -skipPackagePluginValidation \
  test
