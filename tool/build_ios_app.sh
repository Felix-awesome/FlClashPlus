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
LOG_FILE="$ROOT_DIR/dist/ios_build.log"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/dist"

fail() {
  # Emit a GitHub Actions error annotation (surfaces in the run summary) and
  # dump the tail of the captured log so the failure point is visible.
  echo "::error::iOS build failed at: $1" >&2
  if [ -f "$LOG_FILE" ]; then
    echo ">>> last 60 lines of $LOG_FILE:" >&2
    tail -60 "$LOG_FILE" >&2
  fi
  exit 1
}

run() {
  echo "=== [*] $1 ==="
  shift
  "$@" > "$LOG_FILE" 2>&1 || fail "$1"
}

echo "=== [1/6] Ensure Flutter iOS project skeleton ==="
BACKUP_DIR="$(mktemp -d)"
cp -r "$IOS_DIR" "$BACKUP_DIR/ios.bak" 2>/dev/null || true

run "flutter create" $FLUTTER_CMD create --platforms=ios --org com.follow --project-name fl_clash .

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
run "add_ios_extension" ruby "$ROOT_DIR/tool/add_ios_extension.rb" \
  "$IOS_DIR/Runner.xcodeproj" "$BUNDLE_ID" "$APP_GROUP" "$XCFRAMEWORK"

echo "=== [3/6] flutter pub get ==="
run "flutter pub get" $FLUTTER_CMD pub get

echo "=== [4/6] pod install ==="
cd "$IOS_DIR"
run "pod install" pod install

echo "=== [5/6] flutter build ios (unsigned) ==="
cd "$ROOT_DIR"
run "flutter build ios" $FLUTTER_CMD build ios --release --no-codesign

echo "=== [6/6] Package unsigned IPA ==="
cd "$ROOT_DIR/build/ios/iphoneos"
mkdir -p Payload
cp -r Runner.app Payload/
zip -qry "$ROOT_DIR/dist/FlClash-unsigned.ipa" Payload

echo "Built: $ROOT_DIR/dist/FlClash-unsigned.ipa"
