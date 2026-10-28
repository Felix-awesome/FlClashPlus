#!/usr/bin/env bash
# Builds the FlClash Go core as an iOS xcframework via gomobile.
# Usage: bash build_ios_core.sh [output_dir]
set -euo pipefail

CORE_DIR="$(cd "$(dirname "$0")/../core" && pwd)"
OUT_DIR="${1:-$CORE_DIR/../ios/FlClashCore.xcframework}"
TAGS="with_gvisor"
LDFLAGS="-w -s"

VERSION=""
if [ -f "$CORE_DIR/../build_config.yaml" ]; then
  VERSION=$(grep -E '^core_version:' "$CORE_DIR/../build_config.yaml" | sed 's/^core_version:[[:space:]]*//')
fi
if [ -n "$VERSION" ]; then
  LDFLAGS="$LDFLAGS -X github.com/metacubex/mihomo/constant.Version=$VERSION"
fi

echo "Building iOS xcframework from $CORE_DIR"
cd "$CORE_DIR"

gomobile bind \
  -target=ios \
  -o "$OUT_DIR" \
  -tags="$TAGS" \
  -ldflags="$LDFLAGS" \
  ./mobile

echo "Built: $OUT_DIR"
