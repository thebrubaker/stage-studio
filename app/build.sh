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
APP="$HERE/build/StageStudio.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -O \
  -target arm64-apple-macosx14.0 \
  "$HERE"/Sources/*.swift \
  -o "$APP/Contents/MacOS/StageStudio"

# Ad-hoc signature over the whole BUNDLE (swiftc only linker-signs the binary).
# Still "unsigned" for distribution purposes — no Developer ID, no notarization —
# but it gives the bundle a coherent identity. Whether the Screen Recording grant
# survives a rebuild is unverified; if it re-prompts every build we'll know at the
# first real SCK call.
codesign --force --sign - --identifier io.digitalpine.stage-studio "$APP" >/dev/null 2>&1 || \
  echo "warn: ad-hoc codesign failed" >&2

echo "built $APP"
