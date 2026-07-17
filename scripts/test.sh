#!/bin/bash
# Tameo のテストを実行する。
#   ./scripts/test.sh            # 層1(ユニット/統合)＋層2(設定ウィンドウのUI駆動) を全部
#   ./scripts/test.sh unit       # 層1 のみ（速い・CI向き）
#   ./scripts/test.sh ui         # 層2 のみ
#
# 終了コードは xcodebuild のものをそのまま返す（CI・リリース判定が偽の成功を掴まないため）。
# grep は表示を絞るフィルタでしかないので、その終了コードは判定に使わない。
set -eo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

ONLY=""
case "$1" in
  unit) ONLY="-only-testing:TameoTests" ;;
  ui)   ONLY="-only-testing:TameoUITests" ;;
  "")   ONLY="" ;;
  *)    echo "usage: $0 [unit|ui]" >&2; exit 2 ;;
esac

LOG="$(mktemp -t tameo-test)"
trap 'rm -f "$LOG"' EXIT

# パイプの途中に grep を挟むと $? は grep のものになるため、PIPESTATUS[0] で xcodebuild の
# 元の終了コードを取り出す。ここだけ set -e を外すのは、コードを読み取る前に抜けないため。
set +e
xcodebuild test \
  -scheme Tameo \
  -destination 'platform=macOS' \
  -derivedDataPath build/test \
  $ONLY \
  2>&1 | tee "$LOG" \
  | grep -E "Test Case.*(passed|failed)|Executed [0-9]+ tests|\*\* TEST (SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  echo "** TEST FAILED (xcodebuild exit $status)" >&2
  echo "   full log: $LOG (この行の直後に消えるため、再現は再実行で)" >&2
  exit "$status"
fi

# xcodebuild が 0 でも、テストが 1 件も走っていなければ成功扱いにしない
# （-only-testing のタイポやターゲット未リンクを「緑」と誤認しないため）。
if ! grep -qE "Executed [0-9]+ test" "$LOG"; then
  echo "** TEST FAILED (テストが 1 件も実行されていない)" >&2
  exit 1
fi
if grep -qE "Executed 0 tests" "$LOG"; then
  echo "** TEST FAILED (Executed 0 tests)" >&2
  exit 1
fi

exit 0
