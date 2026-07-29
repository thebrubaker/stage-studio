#!/bin/bash
# Package the built app into a signed, notarized, stapled DMG — the artifact a
# second user downloads and drags to /Applications.
#
# Why a DMG and not a zip: dragging the app out of a mounted DMG in Finder is
# the one install gesture that strips the com.apple.quarantine xattr. A
# programmatic copy (or an app launched straight out of a downloaded archive)
# keeps quarantine, and macOS then runs it from a randomized read-only path
# (app translocation), which breaks anything that expects to live at a stable
# location.
#
# Signing alone is not enough for someone else's Mac. A Developer ID signature
# with no notarization ticket gets `spctl` "rejected — Unnotarized Developer ID":
# fine on the machine that built it, blocked on any machine that downloaded it.
# Notarization is Apple scanning the artifact and issuing a ticket; stapling
# attaches that ticket so the check passes without a network round-trip.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/Stage Studio.app"
DIST="$HERE/dist"
DMG="$DIST/Stage-Studio.dmg"
VOL="Stage Studio"

SIGN_ID="${STAGE_STUDIO_SIGN_ID:-Developer ID Application: Joel Brubaker (UQ27DB7N8K)}"

# A notarytool keychain profile is scoped to the Apple *account*, not to an app,
# so one profile notarizes every app you ship. Set this to whichever profile
# already exists on the machine:
#
#   xcrun notarytool history --keychain-profile "$STAGE_STUDIO_NOTARY_PROFILE"
#
# To create one, the account holder runs this themselves (it stores an
# app-specific password from account.apple.com in the keychain):
#
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
NOTARY_PROFILE="${STAGE_STUDIO_NOTARY_PROFILE:-stage-studio}"

if [[ ! -d "$APP" ]]; then
  echo "no app bundle at $APP — run ./app/build.sh first" >&2
  exit 1
fi

# --- Stage --------------------------------------------------------------------
# The /Applications symlink is what makes the DMG window a drag-and-drop target
# instead of a folder the user has to figure out.
STAGE="$(mktemp -d)/$VOL"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# --- Build the image ----------------------------------------------------------
rm -rf "$DIST"
mkdir -p "$DIST"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov -quiet \
  -format UDZO \
  "$DMG"

# Sign the container too, so the thing the user double-clicks carries the same
# identity as the app inside it.
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# --- Notarize -----------------------------------------------------------------
echo "submitting to Apple for notarization (typically a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

xcrun stapler staple "$DMG"

# --- Verify -------------------------------------------------------------------
# This is the verdict the recipient's Mac renders, so it is the only one that
# counts. "accepted, source=Notarized Developer ID" is the pass condition;
# anything else — including "Unnotarized Developer ID" — means do not ship.
echo "--- gatekeeper ---"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "--- offline ticket ---"
xcrun stapler validate "$DMG"

echo "packaged $DMG"
