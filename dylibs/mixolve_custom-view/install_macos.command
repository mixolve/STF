#!/bin/bash
# Source-only mixolve_custom-view: build a single standalone Apple Silicon dylib.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_DIR="${REAPER_USERPLUGINS_DIR:-/Users/kk/Library/CloudStorage/GoogleDrive-mixolve@gmail.com/My Drive/reaper-main/UserPlugins}"
FILENAME='reaper_mixolve_custom-view.dylib'

if [[ "$(uname -s)" != 'Darwin' ]]; then
  echo 'This installer must run on macOS.' >&2; exit 1
fi
for src in wrapper.mm ui.mm keyboard.mm track-name.mm model.cpp model.hpp readout-cell.mm readout-baseline.cpp readout-baseline.hpp objc-hooks.mm objc-hooks.hpp fx-windows.mm fx-windows.hpp; do
  [[ -f "$SCRIPT_DIR/$src" ]] || { echo "Missing: $src" >&2; exit 1; }
done
for tool in xcrun clang++ codesign lipo nm; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [[ ! -d "$DEST_DIR" ]]; then
  echo "UserPlugins directory does not exist: $DEST_DIR" >&2; exit 1
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mixolve-custom-view.XXXXXX")"
trap 'rm -rf -- "$BUILD_DIR"' EXIT

xcrun clang++ -std=c++17 -fobjc-arc -fblocks -dynamiclib -arch arm64 \
  -mmacosx-version-min=11.0 -O2 -fvisibility=hidden \
  -framework AppKit -framework QuartzCore -framework CoreText -framework ApplicationServices \
  -Wl,-install_name,@rpath/reaper_mixolve_custom-view.dylib \
  "$SCRIPT_DIR/wrapper.mm" "$SCRIPT_DIR/ui.mm" "$SCRIPT_DIR/model.cpp" \
  "$SCRIPT_DIR/keyboard.mm" "$SCRIPT_DIR/track-name.mm" \
  "$SCRIPT_DIR/readout-cell.mm" "$SCRIPT_DIR/readout-baseline.cpp" \
  "$SCRIPT_DIR/objc-hooks.mm" "$SCRIPT_DIR/fx-windows.mm" \
  -o "$BUILD_DIR/$FILENAME"

# Verify the resulting architecture and entry point before touching installed files.
[[ "$(xcrun lipo -archs "$BUILD_DIR/$FILENAME")" == 'arm64' ]] || { echo 'Unexpected architecture.' >&2; exit 1; }
xcrun nm -gU "$BUILD_DIR/$FILENAME" | grep -q '_ReaperPluginEntry' || { echo 'REAPER entry point missing.' >&2; exit 1; }
codesign --force --sign - "$BUILD_DIR/$FILENAME"
codesign --verify --strict "$BUILD_DIR/$FILENAME"

# Preserve the currently installed binary as a non-loadable backup before
# replacing an unverified AppKit/UI extension.
if [[ -f "$DEST_DIR/$FILENAME" ]]; then
  BACKUP="$DEST_DIR/${FILENAME}.backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$DEST_DIR/$FILENAME" "$BACKUP"
  printf 'Previous version backed up to:\n  %s\n' "$BACKUP"
fi
# Update the local build first, then the configured UserPlugins path.
cp -f "$BUILD_DIR/$FILENAME" "$SCRIPT_DIR/$FILENAME"
cp -f "$BUILD_DIR/$FILENAME" "$DEST_DIR/$FILENAME"
printf 'Built and installed ARM64 library:\n  %s\n  %s\n' \
  "$SCRIPT_DIR/$FILENAME" "$DEST_DIR/$FILENAME"
echo 'Restart REAPER to load the new extension.'
