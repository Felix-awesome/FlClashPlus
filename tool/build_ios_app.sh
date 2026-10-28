#!/usr/bin/env bash
# Assembles the FlClash iOS app: generates the Flutter iOS project, injects the
# FlClashService NetworkExtension target, links the Go core xcframework, and
# builds an unsigned IPA.
# Usage: bash build_ios_app.sh [bundle_id] [app_group]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${1:-com.follow.clash}"
APP_GROUP="${2:-group.com.follow.clash}"
IOS_DIR="$ROOT_DIR/ios"
XCFRAMEWORK="$IOS_DIR/FlClashCore.xcframework"
FLUTTER_CMD="${FLUTTER_CMD:-flutter}"

cd "$ROOT_DIR"

echo "=== [1/6] Ensure Flutter iOS project skeleton ==="
# flutter create generates Runner.xcodeproj + Runner.xcworkspace + Info.plist.
# It must NOT clobber our Podfile / Swift sources, so back them up first.
BACKUP_DIR="$(mktemp -d)"
cp -r "$IOS_DIR" "$BACKUP_DIR/ios.bak" 2>/dev/null || true

$FLUTTER_CMD create --platforms=ios --org com.follow --project-name fl_clash .

# Restore our custom files over the generated skeleton.
for f in \
  "Runner/AppDelegate.swift" \
  "Runner/Runner.entitlements" \
  "FlClashService/PacketTunnelProvider.swift" \
  "FlClashService/VpnCore.swift" \
  "FlClashService/Info.plist" \
  "FlClashService/FlClashService.entitlements" \
  "Podfile"
do
  if [ -f "$BACKUP_DIR/ios.bak/$f" ]; then
    mkdir -p "$(dirname "$IOS_DIR/$f")"
    cp "$BACKUP_DIR/ios.bak/$f" "$IOS_DIR/$f"
  fi
done

echo "=== [2/6] Add FlClashService extension target to Xcode project ==="
ruby "$ROOT_DIR/tool/add_ios_extension.rb" \
  "$IOS_DIR/Runner.xcodeproj" \
  "$BUNDLE_ID" \
  "$APP_GROUP" \
  "$XCFRAMEWORK"

echo "=== [3/6] flutter pub get ==="
$FLUTTER_CMD pub get

echo "=== [4/6] pod install ==="
cd "$IOS_DIR"
pod install --repo-update

echo "=== [5/6] flutter build ios (unsigned) ==="
cd "$ROOT_DIR"
$FLUTTER_CMD build ios --release --no-codesign

echo "=== [6/6] Package unsigned IPA ==="
mkdir -p "$ROOT_DIR/dist"
cd "$ROOT_DIR/build/ios/iphoneos"
mkdir -p Payload
cp -r Runner.app Payload/
zip -qry "$ROOT_DIR/dist/FlClash-unsigned.ipa" Payload

echo "Built: $ROOT_DIR/dist/FlClash-unsigned.ipa"
