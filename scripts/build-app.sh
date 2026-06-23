#!/bin/sh
# Tameo を Release ビルドして /Applications にインストールする日常用スクリプト。
#   ./scripts/build-app.sh
# ビルド番号(CFBundleVersion)は git のコミット数で自動採番する（修正→コミット→ビルドで +1）。
# 人が読む版(CFBundleShortVersionString=MARKETING_VERSION)は project.yml で手動更新する。
set -e
cd "$(dirname "$0")/.."

BUILD_NUM=$(git rev-list --count HEAD)
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
echo "Building Tameo v$VERSION (build $BUILD_NUM)…"

xcodegen generate
xcodebuild -scheme Tameo -configuration Release -allowProvisioningUpdates \
  -destination 'platform=macOS' \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  -derivedDataPath build/release \
  build

APP="build/release/Build/Products/Release/Tameo.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: build product not found at $APP" >&2
  exit 1
fi

# 起動中なら終了してから差し替え（権限の身元は署名で安定なので再許可不要）。
osascript -e 'quit app "Tameo"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Tameo.app
cp -R "$APP" /Applications/Tameo.app

echo "Installed: /Applications/Tameo.app  (v$VERSION build $BUILD_NUM)"
echo "Launching…"
open /Applications/Tameo.app
