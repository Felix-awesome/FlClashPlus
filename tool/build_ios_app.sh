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
    # Emit the TAIL of the log plus any compiler/xcodebuild error lines. The
    # real error is usually at the end, but flutter swallows xcodebuild output
    # when the build dies very early, so also surface matched error keywords.
    local detail tail_lines err_lines
    tail_lines="$(tail -200 "$LOG_FILE")"
    err_lines="$(grep -nE 'error:|fatal error:|BUILD FAILED|ld: |Undefined symbol|No such module|CompileSwift|CompileC|Error \(Xcode\)|Failed to build' "$LOG_FILE" | tail -80 || true)"
    detail="${tail_lines}"
    if [ -n "$err_lines" ]; then
      detail="${detail}
=== ERROR LINES ===
${err_lines}"
    fi
    detail="$(printf '%s' "$detail" | sed 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
    msg="${msg}%0A%0A--- LOG (tail 200 + error lines) ---%0A${detail}"
  fi
  echo "::error::${msg}" >&2
  exit 1
}

# run_capture runs a command, teeing output to BOTH stdout (so it lands in the
# step log) and LOG_FILE (so fail() can quote it, and the artifact upload in
# the workflow can publish the full log). This matters because the
# flutter build ios error is otherwise only visible inside LOG_FILE, which the
# runner's step log does not show.
run() {
  local label="$1"
  shift
  echo "=== [$label] ==="
  # Tee to stdout (step log) + LOG_FILE. The pipeline must not trigger `set -e`
  # before we can capture the exit status, so guard it with a conditional.
  if ! "$@" 2>&1 | tee "$LOG_FILE"; then
    fail "$label"
  fi
}

# The Go core is already built as FlClashCore.xcframework (gomobile bind), and
# the iOS core talks to the app over MethodChannel -- the desktop/Android
# native assets (setup's Go build, rust_api's IPC/rquickjs) are not needed on
# iOS. Skip both hooks up front so the first `flutter create`/`pub get` already
# resolves against the final pubspec (avoiding a mid-script pubspec change that
# would force `flutter build ios` to re-resolve dependencies).
# NOTE: use sed (a plain text substitution) rather than yq. yq re-serializes the
# whole file through a YAML-1.1 parser, which can rewrite scalar values (e.g.
# 'none', 'on'/'off') and silently break the pubspec for pub.
sed -i.bak 's/^\([[:space:]]*\)build_assets: true$/\1build_assets: false/' pubspec.yaml
rm -f pubspec.yaml.bak

echo "=== [1/7] Ensure Flutter iOS project skeleton ==="
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

echo "=== [2/7] flutter pub get (generate SPM integration) ==="
run "flutter pub get" $FLUTTER_CMD pub get

echo "=== [3/7] Add FlClashService extension target to Xcode project ==="
run "add_ios_extension" ruby "$ROOT_DIR/tool/add_ios_extension.rb" \
  "$IOS_DIR/Runner.xcodeproj" "$BUNDLE_ID" "$APP_GROUP" "$XCFRAMEWORK"

echo "=== [4/7] flutter pub get (restore SPM integration) ==="
run "flutter pub get" $FLUTTER_CMD pub get

echo "=== [5/7] flutter build ios (unsigned, verbose) ==="
cd "$ROOT_DIR"
# -v prints the full xcodebuild invocation and its output, which is the only
# way to see why the build dies before emitting any Swift compile errors.
run "flutter build ios" $FLUTTER_CMD build ios --release --no-codesign -v

echo "=== [6/7] Package unsigned IPA ==="
cd "$ROOT_DIR/build/ios/iphoneos"
mkdir -p Payload
cp -r Runner.app Payload/
zip -qry "$ROOT_DIR/dist/FlClash-unsigned.ipa" Payload

echo "=== [7/7] Package TrollStore IPA (ad-hoc signed, entitlements kept) ==="
# TrollStore does not check a certificate chain, so a bundle installed that way
# can keep entitlements no provisioning profile would ever grant -- Network
# Extension and the App Group included. That makes it the only route to a
# working tunnel without a paid developer account. `ldid -S` writes an ad-hoc
# signature carrying the given entitlements, and TrollStore preserves them when
# it re-signs during install. Skipped rather than failed when ldid is missing:
# the unsigned IPA above stays the primary artifact.
if command -v ldid >/dev/null 2>&1; then
  rm -rf PayloadTroll
  mkdir -p PayloadTroll/Payload
  cp -r Runner.app PayloadTroll/Payload/
  ldid -S"$ROOT_DIR/ios/Runner/Runner.entitlements" \
    PayloadTroll/Payload/Runner.app/Runner
  ldid -S"$ROOT_DIR/ios/FlClashService/FlClashService.entitlements" \
    PayloadTroll/Payload/Runner.app/PlugIns/FlClashService.appex/FlClashService
  rm -f "$ROOT_DIR/dist/FlClash-trollstore.ipa"
  if ( cd PayloadTroll && zip -qry "$ROOT_DIR/dist/FlClash-trollstore.ipa" Payload ); then
    echo "Built: $ROOT_DIR/dist/FlClash-trollstore.ipa"
  else
    echo "::warning::TrollStore packaging failed, the unsigned IPA is unaffected"
  fi
else
  echo "ldid not found, skipping the TrollStore package"
fi

echo "Built: $ROOT_DIR/dist/FlClash-unsigned.ipa"
