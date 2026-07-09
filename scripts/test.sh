#!/bin/sh
# Tameo のテストを実行する。
#   ./scripts/test.sh            # 層1(ユニット/統合)＋層2(設定ウィンドウのUI駆動) を全部
#   ./scripts/test.sh unit       # 層1 のみ（速い・CI向き）
#   ./scripts/test.sh ui         # 層2 のみ
set -e
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

ONLY=""
case "$1" in
  unit) ONLY="-only-testing:TameoTests" ;;
  ui)   ONLY="-only-testing:TameoUITests" ;;
  "")   ONLY="" ;;
  *)    echo "usage: $0 [unit|ui]" >&2; exit 2 ;;
esac

xcodebuild test \
  -scheme Tameo \
  -destination 'platform=macOS' \
  -derivedDataPath build/test \
  $ONLY \
  | grep -E "Test Case.*(passed|failed)|Executed [0-9]+ tests|\*\* TEST (SUCCEEDED|FAILED)" \
  || true
