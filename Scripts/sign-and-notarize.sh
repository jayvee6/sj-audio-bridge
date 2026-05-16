#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"
# Derive names AFTER sourcing version.env (it sets APP_NAME/APP_IDENTITY) —
# computing them before the source froze them to the MyApp default.
APP_NAME=${APP_NAME:-MyApp}
APP_IDENTITY=${APP_IDENTITY:-"Developer ID Application: Example (TEAMID)"}
APP_BUNDLE="${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"

# Notarization auth via a keychain profile (stored once with
# `xcrun notarytool store-credentials "$NOTARY_PROFILE"`). No secrets on
# disk or in env — see version.env NOTARY_PROFILE.
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "version.env must set NOTARY_PROFILE (notarytool keychain profile name)." >&2
  exit 1
fi
trap 'rm -f /tmp/${APP_NAME}Notarize.zip' EXIT

ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c release --arch "$ARCH"
done
ARCHES="${ARCHES_VALUE}" "$ROOT/Scripts/package_app.sh" release

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-${ENTITLEMENTS_DIR}/${APP_NAME}.entitlements}"

codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_BUNDLE"

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

xcrun notarytool submit "/tmp/${APP_NAME}Notarize.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$APP_BUNDLE"

xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

spctl -a -t exec -vv "$APP_BUNDLE"
stapler validate "$APP_BUNDLE"

echo "Done: $ZIP_NAME"
