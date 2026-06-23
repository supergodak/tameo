#!/bin/sh
# Developer ID 署名の Release ビルド → 署名済みDMG を作る配布用スクリプト。
#   ./scripts/release.sh
# 公証まで自動化するなら（事前に `xcrun notarytool store-credentials <profile>` で資格情報を保存）:
#   NOTARY_PROFILE=tameo-notary ./scripts/release.sh
# ビルド番号(CFBundleVersion)は git コミット数で自動採番。
set -e
cd "$(dirname "$0")/.."

BUILD_NUM=$(git rev-list --count HEAD)
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
DDP="build/release"
APP="$DDP/Build/Products/Release/Tameo.app"
DMG="build/Tameo-$VERSION.dmg"
ID="Developer ID Application: ATI K.K. (8NY87P5TYV)"

echo "==> Building Release (Developer ID) v$VERSION (build $BUILD_NUM)…"
xcodegen generate
xcodebuild -scheme Tameo -configuration Release -allowProvisioningUpdates \
  -destination 'platform=macOS' -derivedDataPath "$DDP" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

[ -d "$APP" ] || { echo "ERROR: build product not found at $APP" >&2; exit 1; }

echo "==> Verifying signature (Developer ID + hardened runtime + secure timestamp)…"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|Runtime|flags=" || true
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating DMG (with drag-to-Applications)…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p build
rm -f "$DMG"
hdiutil create -volname "Tameo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$ID" "$DMG"
echo "    DMG: $DMG"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Notarizing with keychain profile '$NOTARY_PROFILE'…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> Notarized & stapled: $DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG" || true
else
  echo "==> Next (notarize, needs your Apple ID credentials once):"
  echo "    xcrun notarytool store-credentials tameo-notary --apple-id <ATI Apple ID> --team-id 8NY87P5TYV --password <app-specific-password>"
  echo "    xcrun notarytool submit \"$DMG\" --keychain-profile tameo-notary --wait"
  echo "    xcrun stapler staple \"$DMG\""
fi
echo "==> Done. v$VERSION (build $BUILD_NUM)"
