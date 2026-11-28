#!/bin/bash
# Source-only mixolve_custom-view: build a single standalone Apple Silicon dylib.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_DIR="$PROJECT_DIR/source"
# Never silently install into a hardcoded /Users/<someone> folder.
# Prefer an existing configured resource directory; explicit override wins.
if [[ -n "${REAPER_USERPLUGINS_DIR:-}" ]]; then
  DEST_DIR="$REAPER_USERPLUGINS_DIR"
else
  DEFAULT_RESOURCE="$HOME/Library/Application Support/REAPER"
  CLOUD_RESOURCE="$HOME/Library/CloudStorage/GoogleDrive-mixolve@gmail.com/My Drive/reaper-main"
  if [[ -f "$CLOUD_RESOURCE/reaper.ini" && ! -f "$DEFAULT_RESOURCE/reaper.ini" ]]; then
    DEST_DIR="$CLOUD_RESOURCE/UserPlugins"
  elif [[ -f "$DEFAULT_RESOURCE/reaper.ini" && ! -f "$CLOUD_RESOURCE/reaper.ini" ]]; then
    DEST_DIR="$DEFAULT_RESOURCE/UserPlugins"
  elif [[ -f "$CLOUD_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" && ! -f "$DEFAULT_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" ]]; then
    DEST_DIR="$CLOUD_RESOURCE/UserPlugins"
  elif [[ -f "$DEFAULT_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" && ! -f "$CLOUD_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" ]]; then
    DEST_DIR="$DEFAULT_RESOURCE/UserPlugins"
  elif [[ -f "$CLOUD_RESOURCE/reaper.ini" && -f "$DEFAULT_RESOURCE/reaper.ini" ]] ||
       [[ -f "$CLOUD_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" && -f "$DEFAULT_RESOURCE/UserPlugins/reaper_mixolve_custom-view.dylib" ]]; then
    echo 'Multiple REAPER resource folders detected. Specify the active UserPlugins folder:' >&2
    echo '  REAPER_USERPLUGINS_DIR="/path/to/active/UserPlugins" bash temp/install_macos.command' >&2
    exit 1
  else
    DEST_DIR="$DEFAULT_RESOURCE/UserPlugins"
  fi
fi
FILENAME='reaper_mixolve_custom-view.dylib'

if [[ "$(uname -s)" != 'Darwin' ]]; then
  echo 'This installer must run on macOS.' >&2; exit 1
fi
SOURCES=(
  "$SOURCE_DIR/wrapper.mm" "$SOURCE_DIR/ui.mm" "$SOURCE_DIR/model.cpp"
  "$SOURCE_DIR/keyboard.mm" "$SOURCE_DIR/track-name.mm"
  "$SOURCE_DIR/readout-cell.mm" "$SOURCE_DIR/readout-baseline.cpp"
  "$SOURCE_DIR/objc-hooks.mm" "$SOURCE_DIR/fx-windows.mm"
  "$SOURCE_DIR/take-volume-actions.cpp"
)
HEADERS=(
  "$SOURCE_DIR/cpu-status.hpp" "$SOURCE_DIR/fx-windows.hpp"
  "$SOURCE_DIR/main-toolbar-target.hpp" "$SOURCE_DIR/model.hpp"
  "$SOURCE_DIR/objc-hooks.hpp" "$SOURCE_DIR/readout-baseline.hpp"
  "$SOURCE_DIR/toolbar-readout-layout.hpp" "$SOURCE_DIR/track-volume-layout.hpp"
  "$SOURCE_DIR/track-volume.hpp"
)
for src in "${SOURCES[@]}" "${HEADERS[@]}"; do
  [[ -f "$src" ]] || { echo "Missing: $src" >&2; exit 1; }
done
# Theme variations are OPTIONAL. The TCP overlay paints its own full #222222
# cell, so the extension can be built from a source-only archive and used
# with the currently active theme without overwriting theme assets.
for tool in xcrun clang++ codesign lipo nm strings; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [[ ! -d "$DEST_DIR" ]]; then
  echo "UserPlugins directory does not exist: $DEST_DIR" >&2
  echo 'Open REAPER > Options > Show REAPER resource path and use its UserPlugins directory:' >&2
  echo '  REAPER_USERPLUGINS_DIR="/path/to/UserPlugins" bash temp/install_macos.command' >&2
  exit 1
fi
printf 'INSTALL TARGET: %s\n' "$DEST_DIR"
echo 'Confirm this matches the UserPlugins directory in your active REAPER resource path.'
RESOURCE_DIR="$(dirname "$DEST_DIR")"
THEME_DIR="$RESOURCE_DIR/ColorThemes"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mixolve-custom-view.XXXXXX")"
trap 'rm -rf -- "$BUILD_DIR"' EXIT

xcrun clang++ -std=c++17 -fobjc-arc -fblocks -dynamiclib -arch arm64 \
  -mmacosx-version-min=11.0 -O2 -fvisibility=hidden \
  -framework AppKit -framework QuartzCore -framework CoreText -framework ApplicationServices -framework Carbon \
  -Wl,-install_name,@rpath/reaper_mixolve_custom-view.dylib \
  "${SOURCES[@]}" \
  -o "$BUILD_DIR/$FILENAME"

# Verify the resulting architecture and entry point before touching installed files.
[[ "$(xcrun lipo -archs "$BUILD_DIR/$FILENAME")" == 'arm64' ]] || { echo 'Unexpected architecture.' >&2; exit 1; }
xcrun nm -gU "$BUILD_DIR/$FILENAME" | grep '_ReaperPluginEntry' >/dev/null || { echo 'REAPER entry point missing.' >&2; exit 1; }
# Read the actual marker from ui.mm, rather than retaining an old version in
# the installer when the UI changes. Never touch the installed library if
# the new compiled binary does not contain the marker it was built from.
EXPECTED_MARKER="$(sed -n 's/.*kMixolveToolbarBuild="\([^"]*\)".*/\1/p' "$SOURCE_DIR/ui.mm" | head -n 1)"
if [[ -z "$EXPECTED_MARKER" ]]; then
  echo 'Unable to read UI build marker from ui.mm.' >&2; exit 1
fi
if ! strings "$BUILD_DIR/$FILENAME" | grep -Fx "$EXPECTED_MARKER" >/dev/null; then
  echo "Build marker $EXPECTED_MARKER missing from compiled library." >&2; exit 1
fi
codesign --force --sign - "$BUILD_DIR/$FILENAME"
codesign --verify --strict "$BUILD_DIR/$FILENAME"

# Update the local build first, then the configured UserPlugins path.
cp -f "$BUILD_DIR/$FILENAME" "$PROJECT_DIR/$FILENAME"
cp -f "$BUILD_DIR/$FILENAME" "$DEST_DIR/$FILENAME"
# Install theme variations only if actually provided. Never require theme
# files absent from a source distribution or modify an active user theme.
INSTALLED_THEMES=0
for theme in Default_7.0_mixolve_nativeless.ReaperThemeZip mixolve_deftweaked.ReaperTheme; do
  if [[ -f "$PROJECT_DIR/$theme" ]]; then
    mkdir -p "$THEME_DIR"
    cp -f "$PROJECT_DIR/$theme" "$THEME_DIR/$theme"
    echo "Optional theme installed: $theme"
    INSTALLED_THEMES=$((INSTALLED_THEMES+1))
  fi
done
if [[ "$INSTALLED_THEMES" -eq 0 ]]; then
  echo 'No optional theme files supplied; the readout uses the current REAPER theme.'
fi
printf 'Built and installed ARM64 library:\n  %s\n  %s\n' \
  "$PROJECT_DIR/$FILENAME" "$DEST_DIR/$FILENAME"
echo 'Restart REAPER to load the new extension.'

echo 'After restarting REAPER, check:'
echo '  ~/Library/Logs/mixolve-custom-view-toolbar.log'
echo 'The final line should include toolbar=swell-native-toolbar (or swell-cocoa-screen-rect / appkit-toolbar / swell-tcp-anchored-toolbar), target=yes, overlay=yes.'
