#!/bin/bash
# Puts the root helper inside Caz.app, signs both with their entitlements and zips Caz.tipa.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Release-iphoneos/Caz.app"
[ -d "$APP" ] || { echo "Caz.app not found at $APP"; exit 1; }
[ -f build/cazhelper ] || { echo "build/cazhelper not found"; exit 1; }

cp build/cazhelper "$APP/cazhelper"
rm -rf "$APP/_CodeSignature" "$APP/embedded.mobileprovision"

ldid -SRootHelper/entitlements.plist "$APP/cazhelper"
ldid -SConfig/Caz.entitlements "$APP/Caz"
chmod 755 "$APP/Caz" "$APP/cazhelper"

rm -rf build/Payload build/Caz.tipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry Caz.tipa Payload)
echo "Built build/Caz.tipa ($(du -h build/Caz.tipa | cut -f1))"
