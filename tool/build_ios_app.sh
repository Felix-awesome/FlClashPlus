#!/usr/bin/env bash
# Assembles the FlClash iOS app: generates the Flutter iOS project, injects the
# FlClashService NetworkExtension target, links the Go core xcframework, and
# builds an unsigned IPA.
#
# Flutter 3.44+ uses Swift Package Manager (not CocoaPods) to integrate iOS
# plugins. "flutter pub get" generates the FlutterGeneratedPluginSwiftPackage
# SPM reference in Runner.xcodeproj. Because add_ios_extension.rb rewrites the
# project with the xcodeproj gem (which can drop SPM package references), we
# run pub get BEFORE and AFTER it.
#
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
  local label="$1"
  local msg="iOS build failed at: ${label}"
  if [ -f "$LOG_FILE" ]; then
    # Dump the WHOLE log (flutter build ios logs are short) so the real error
    # is visible in the annotation. Escape % \r \n for ::error::.
    local full
    full="$(cat "$LOG_FILE" | sed 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
    msg="${msg}%0A%0A--- FULL LOG ---%0A${full}"
  fi
  echo "::error::${msg}" >&2
  exit 1
}

run() {
  local label="$1"
  shift
  echo "=== [$label] ==="
  if ! "$@" > "$LOG_FILE" 2>&1; then
    fail "$label"
  fi
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
  "FlClashService/FlClashService.entitlements"
do
  if [ -f "$BACKUP_DIR/ios.bak/$f" ]; then
    mkdir -p "$(dirname "$IOS_DIR/$f")"
    cp "$BACKUP_DIR/ios.bak/$f" "$IOS_DIR/$f"
  fi
done

echo "=== [2/6] flutter pub get (generate SPM integration) ==="
run "flutter pub get" $FLUTTER_CMD pub get

echo "=== [3/6] Add FlClashService extension target to Xcode project ==="
run "add_ios_extension" ruby "$ROOT_DIR/tool/add_ios_extension.rb" \
  "$IOS_DIR/Runner.xcodeproj" "$BUNDLE_ID" "$APP_GROUP" "$XCFRAMEWORK"

echo "=== [4/6] flutter pub get (restore SPM integration) ==="
run "flutter pub get" $FLUTTER_CMD pub get

# The Go core is already built as FlClashCore.xcframework (gomobile bind), and
# the iOS core talks to the app over MethodChannel -- the desktop/Android
# native assets (setup's Go build, rust_api's IPC/rquickjs) are not needed on
# iOS. Skip both hooks so `flutter build ios` does not try to cross-compile
# them (rust_api's Cargo.toml has no iOS target config and would fail).
if command -v yq >/dev/null 2>&1; then
  yq -i '.hooks.user_defines.setup.build_assets = false | .hooks.user_defines.rust_api.build_assets = false' pubspec.yaml
else
  sed -i.bak 's/^\(\s*\)build_assets: true$/\1build_assets: false/' pubspec.yaml
fi

echo "=== [5/6] flutter build ios (unsigned) ==="
cd "$ROOT_DIR"
run "flutter build ios" $FLUTTER_CMD build ios --release --no-codesign

echo "=== [6/6] Package unsigned IPA ==="
cd "$ROOT_DIR/build/ios/iphoneos"
mkdir -p Payload
cp -r Runner.app Payload/
zip -qry "$ROOT_DIR/dist/FlClash-unsigned.ipa" Payload

echo "Built: $ROOT_DIR/dist/FlClash-unsigned.ipa"
