#!/bin/bash
# Builds Onyx Scribe.app and installs it to /Applications.
# Usage: ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "▸ Building release binary…"
swift build -c release

echo "▸ Release-safety check…"
./scripts/check-release-safety.sh .build/release/FlowClone

APP="Onyx Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Support/Info.plist "$APP/Contents/Info.plist"
cp .build/release/FlowClone "$APP/Contents/MacOS/FlowClone"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the SPM resources (Fraunces display font) so `Bundle.module` resolves
# inside the packaged .app, not just the debug binary. Without this the app
# falls back to the system serif.
RESBUNDLE=".build/release/FlowClone_FlowClone.bundle"
if [ -d "$RESBUNDLE" ]; then
  cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
else
  echo "⚠️  Resource bundle not found at $RESBUNDLE — bundled font will fall back to system serif."
fi

# Signing. Three tiers, best available first:
#  1. Developer ID Application  → hardened runtime + entitlements + timestamp
#     (the release path; also enables notarization below). Auto-detected, or pin
#     with DEVID_IDENTITY="Developer ID Application: Your Name (TEAMID)".
#  2. "FlowClone Dev" self-signed → stable local identity (TCC grants survive
#     rebuilds). The current dev default.
#  3. ad-hoc → last resort (permissions re-granted after each rebuild).
ENTITLEMENTS="Support/FlowClone.entitlements"
DEVID="${DEVID_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -o 'Developer ID Application: [^"]*' | head -1 || true)}"

if [ -n "$DEVID" ]; then
  echo "▸ Signing with Developer ID (hardened runtime): $DEVID"
  # Sign nested code first, then the app, with the hardened runtime.
  find "$APP/Contents/Resources" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$DEVID" {} 2>/dev/null || true
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP"
  NOTARIZE_READY=1
elif security find-identity -v -p codesigning | grep -q "FlowClone Dev"; then
  echo "▸ Signing with FlowClone Dev identity (self-signed, local)…"
  codesign --force --deep --sign "FlowClone Dev" "$APP"
else
  echo "▸ Signing (ad-hoc — permissions will need re-granting after each rebuild)…"
  codesign --force --deep --sign - "$APP"
fi

# Notarization (only with a Developer ID signature). Provide a stored notarytool
# credential profile in NOTARY_PROFILE to run it; otherwise it's skipped with a
# hint. Requires full Xcode's notarytool (not present under CommandLineTools-only).
if [ "${NOTARIZE_READY:-0}" = "1" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ] && xcrun --find notarytool >/dev/null 2>&1; then
    echo "▸ Notarizing (profile: $NOTARY_PROFILE)…"
    ZIP="$(mktemp -d)/FlowClone.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "  ✅ notarized + stapled"
  else
    echo "  ℹ️  Signed with Developer ID but not notarized."
    echo "     Set NOTARY_PROFILE (see: xcrun notarytool store-credentials) and"
    echo "     install full Xcode to enable the notarize+staple step."
  fi
fi

DEST="/Applications/$APP"
echo "▸ Installing to ${DEST} ..."
rm -rf "$DEST"
if cp -R "$APP" /Applications/ 2>/dev/null; then
  rm -rf "$APP"
else
  DEST="$HOME/Applications/$APP"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  mv "$APP" "$HOME/Applications/"
  echo "  (no write access to /Applications — installed to ~/Applications instead)"
fi

echo
echo "✅ Installed: $DEST"
echo "   Launch:  open \"$DEST\""
echo
echo "   If signed with FlowClone Dev, permissions persist across rebuilds."
