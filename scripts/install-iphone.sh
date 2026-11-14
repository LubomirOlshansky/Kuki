#!/bin/zsh
# Build the newest Kūki and install it on a connected iPhone.
# Usage:  ./scripts/install-iphone.sh            (first connected iPhone)
#         ./scripts/install-iphone.sh <UDID>
set -euo pipefail
cd "$(dirname "$0")/.."

UDID=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /(available|connected)/ && !/simulated/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')}
[[ -n "$UDID" ]] || { echo "No iPhone found — connect it (cable or same Wi-Fi) and unlock it."; exit 1; }

echo "› Building Kūki for iPhone $UDID…"
xcodebuild build \
  -project Kuki.xcodeproj -scheme Kuki -configuration Release \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath build.noindex/install-iphone -allowProvisioningUpdates \
  -quiet

echo "› Installing…"
xcrun devicectl device install app --device "$UDID" build.noindex/install-iphone/Build/Products/Release-iphoneos/Kuki.app
echo "› Done — open Kūki on your iPhone."
