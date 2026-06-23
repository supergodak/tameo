#!/bin/sh
# Tameo の配布・LP 計測を一目で表示する（プライバシー: クライアント側トラッキング無し）。
#   ./scripts/stats.sh
# - GitHub Release の実ダウンロード数（GitHub が標準集計。API は公開リポジトリなら認証不要）
# - LP(tameo.ati-mirai.co.jp) の表示数・/dl クリック数（VPS の nginx ログをサーバ側集計）
REPO="supergodak/tameo"

echo "=== GitHub Release downloads ==="
curl -s "https://api.github.com/repos/$REPO/releases" | python3 -c '
import sys, json
try:
    rs = json.load(sys.stdin)
except Exception:
    print("  (API 取得失敗 — リポジトリ非公開 or ネットワーク)"); sys.exit()
if not isinstance(rs, list) or not rs:
    print("  (リリース未公開)"); sys.exit()
for r in rs:
    tag = str(r.get("tag_name"))
    assets = r.get("assets", [])
    if not assets:
        print("  " + tag + ": (アセットなし)")
    for a in assets:
        print("  " + tag + " / " + a["name"] + ": " + str(a["download_count"]) + " downloads")
'

echo
echo "=== LP  https://tameo.ati-mirai.co.jp ==="
ssh -o BatchMode=yes -o ConnectTimeout=12 sakura '
LOG=/var/log/nginx/tameo.access.log
if [ ! -f "$LOG" ]; then echo "  (ログなし)"; exit 0; fi
echo "  ページ表示 (GET / 200):    $(grep -c "GET / HTTP" "$LOG" 2>/dev/null)"
echo "  ユニークIP (概算):         $(awk "{print \$1}" "$LOG" | sort -u | wc -l | tr -d " ")"
echo "  ダウンロードクリック (/dl): $(grep -cE " /dl[ ?]" "$LOG" 2>/dev/null)"
echo "  期間: $(head -1 "$LOG" | grep -oE "\[[^]]+\]" | head -1) 〜 $(tail -1 "$LOG" | grep -oE "\[[^]]+\]" | head -1)"
'
echo
echo "（詳細ダッシュボードが欲しい場合は VPS で: goaccess /var/log/nginx/tameo.access.log）"
