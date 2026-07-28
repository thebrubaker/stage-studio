#!/bin/bash
# Build the stage-studio hotkey recorder into an unsigned .app bundle.
#
# A bundle (rather than a bare binary) is what gives the app a stable TCC identity
# for Screen Recording / Microphone — a raw swiftc binary would inherit the
# grant of whatever terminal launched it, which is exactly the coupling this app
# exists to remove.
#
# Deliberately no signing / notarization: single-user local phase.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$HERE/build/Stage Studio.app"

# Developer ID, not ad-hoc. TCC keys a grant to the code-signing identity, so an
# ad-hoc signature (whose identity changes every build) makes macOS treat each
# rebuild as a brand-new app and forget every permission. A real signing identity
# plus a frozen bundle id is what makes a grant stick.
SIGN_ID="${STAGE_STUDIO_SIGN_ID:-Developer ID Application: Joel Brubaker (UQ27DB7N8K)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -O \
  -target arm64-apple-macosx14.0 \
  "$HERE"/Sources/*.swift \
  -o "$APP/Contents/MacOS/StageStudio"

# --- App icon -------------------------------------------------------------
# icon-master.png is the source art inset to the macOS icon grid (824 of 1024,
# centred). The source is a full-bleed iOS icon; dropped in as-is it renders
# visibly larger than every neighbouring Dock icon, because macOS expects the
# artwork to sit inside a margin rather than fill the tile.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$HERE/Resources/icon-master.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$HERE/Resources/icon-master.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- Embedded helpers -----------------------------------------------------
# The app carries its own recorder and background art so it can live in
# /Applications and keep working — it must not reach back into a checkout that
# may be moved or deleted. Falls back to the repo copies for dev builds.
if [[ -x "$REPO/cmd/recorder/recorder" ]]; then
  cp "$REPO/cmd/recorder/recorder" "$APP/Contents/MacOS/recorder"
fi
if [[ -f "$REPO/assets/big-sur-graphic.jpg" ]]; then
  cp "$REPO/assets/big-sur-graphic.jpg" "$APP/Contents/Resources/big-sur-graphic.jpg"
fi

# --- Signing --------------------------------------------------------------
# Inside out: nested code must be signed before the bundle that contains it, or
# the outer signature seals over unsigned code and fails validation.
#
# --options runtime (hardened runtime) is required for notarization later. It
# also gates microphone access behind an entitlement, hence the entitlements
# file on BOTH binaries.
ENTS="$HERE/Resources/StageStudio.entitlements"
SIGN_FLAGS=(--force --options runtime --timestamp --entitlements "$ENTS" --sign "$SIGN_ID")

if [[ -f "$APP/Contents/MacOS/recorder" ]]; then
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/recorder"
fi
codesign "${SIGN_FLAGS[@]}" "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "built $APP"
