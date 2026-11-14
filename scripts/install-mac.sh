#!/bin/zsh
# Build the newest Kūki for this Mac and install it into /Applications.
# Usage:  ./scripts/install-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› Building Kūki (Release, signed with your team)…"
xcodebuild build \
  -project Kuki.xcodeproj -scheme Kuki -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build.noindex/install-mac -allowProvisioningUpdates \
  -quiet

APP=build.noindex/install-mac/Build/Products/Release-maccatalyst/Kuki.app
codesign --verify --deep --strict "$APP"

echo "› Replacing /Applications/Kuki.app…"
pkill -f "/Applications/Kuki.app/Contents/MacOS/Kuki" 2>/dev/null || true
sleep 1
ditto "$APP" /Applications/Kuki.app

echo "› Starting Kūki — look for the CO₂ number in the menu bar (top right)."
open /Applications/Kuki.app
