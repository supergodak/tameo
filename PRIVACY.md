# Privacy Policy / プライバシーポリシー

_Tameo — macOS clipboard manager by ATI Inc. (ATI株式会社)_

**Last updated: 2026-06-23**

> **Tameo keeps everything on your Mac. Nothing is ever sent off your device.**
> **Tameo のデータはすべてあなたの Mac の中だけにあります。外部へ送信することは一切ありません。**

---

## English

### 1. Summary

Tameo is a local-only clipboard manager. It stores your clipboard history on your own Mac and never transmits it anywhere. There are **no servers, no accounts, no analytics, no telemetry, and no crash reporting**. ATI Inc. cannot see your data, because it never leaves your device.

### 2. What data Tameo handles

- **Clipboard history** — when you copy something, Tameo saves a local copy so you can paste it again later (text, rich text, PDF, images, file paths, URLs, color codes).
- **Snippets** — text snippets you create or import yourself.
- **Settings** — your preferences (history size, hotkeys, enabled data types, excluded apps).

### 3. Where it is stored

All of the above is stored **only on your Mac**, in the app's local database in your user Library (Application Support) plus on-disk sidecar files for large items. It is **not** synced to iCloud, uploaded to any server, or shared with ATI Inc. or any third party.

### 4. Privacy-aware monitoring

To detect a new clipboard item, Tameo checks **only the _type_ of data** on the pasteboard (e.g. "there is text"). It does **not** read the actual contents in the background; contents are read **only when you choose an item** to use it.

### 5. Excluded data

- **Concealed / sensitive items.** Items flagged as concealed (`org.nspasteboard.ConcealedType`) by password managers are **not saved**.
- **Excluded apps.** You can exclude specific apps so that anything copied while they are frontmost is never recorded.
- Temporary and auto-generated items are always skipped.

### 6. Accessibility permission

Tameo asks for macOS **Accessibility** permission for a single purpose: to synthesize a ⌘V keystroke to paste the item you selected into the app you were using. It does **not** read your screen, observe other apps, or log keystrokes.

### 7. Network access

Tameo's core features work **fully offline**. The only network activity (when enabled in a future release) is the optional **automatic update check** via Sparkle: the app contacts ATI's update feed to see whether a newer version exists. As with any download, this reveals your IP address and the app version to the update server — but **no clipboard data, personal data, or identifiers are sent**. You can disable automatic update checks.

### 8. Data retention and deletion

History is capped at the number of items you configure; older items are removed automatically. You can clear all history or delete individual items at any time. Removing the app deletes its local database and sidecar files.

### 9. Children

Tameo is a general productivity tool, not directed at children, and collects no personal information from anyone.

### 10. Open source

Tameo is open source (MIT). You can verify exactly what it does — including that it makes no network calls for its core features — in its public source code.

### 11. Changes

Updated versions of this policy are published with each release and dated above.

### 12. Contact

ATI Inc. (ATI株式会社) — https://tameo.ati-mirai.co.jp · security & privacy contact: tameo@ati-mirai.co.jp

---

## 日本語

### 1. 概要

Tameo は完全ローカルのクリップボードマネージャです。クリップボード履歴はあなたの Mac の中にだけ保存し、どこにも送信しません。**サーバー・アカウント・解析・テレメトリ・クラッシュレポートは一切ありません。** データは端末から出ないため、ATI株式会社があなたのデータを見ることはできません。

### 2. Tameo が扱うデータ

- **クリップボード履歴**：コピーした内容（テキスト・リッチテキスト・PDF・画像・ファイルパス・URL・カラーコード）を再ペースト用に端末内へ控えます。
- **スニペット**：あなた自身が作成・インポートした定型文。
- **設定**：履歴件数・ホットキー・保存する種別・除外アプリなど。

### 3. 保存場所

上記はすべて**あなたの Mac の中だけ**（ユーザーの Library / Application Support のローカルDB＋大きい項目用のサイドカーファイル）に保存します。iCloud 同期も、サーバーへのアップロードも、ATI株式会社や第三者への共有も行いません。

### 4. プライバシー対応の監視

新しい項目の検知では、ペーストボード上の**「種別」だけ**を調べます。中身をバックグラウンドで読むことはせず、**あなたが項目を選んで使う瞬間にだけ**読みます。

### 5. 保存しないデータ

- **機密項目**：パスワードマネージャ等の機密フラグ（`org.nspasteboard.ConcealedType`）付き項目は保存しません。
- **除外アプリ**：指定アプリが前面の間にコピーした内容は記録しません。
- 一時／自動生成データは常にスキップします。

### 6. アクセシビリティ権限

macOS の**アクセシビリティ**権限は、選んだ項目を直前のアプリへ貼り付けるための ⌘V 合成のみに使います。画面の読み取り・他アプリの監視・キーロギングには使いません。

### 7. ネットワーク

中核機能は**完全オフライン**で動作します。将来のリリースで有効化される唯一の通信は、任意の**自動アップデート確認**（Sparkle）です：ATI のアップデートフィードへ新バージョンの有無を確認します。一般的なダウンロードと同様 IP とバージョンが伝わりますが、**クリップボードのデータ・個人情報・識別子は一切送信しません**。自動確認は無効化できます。

### 8. 保持と削除

履歴は設定件数で上限管理され、古い項目は自動削除されます。全消去・個別削除はいつでも可能。アプリ削除でローカルDBとサイドカーも削除されます。

### 9. 子どもについて

Tameo は一般的な生産性ツールであり、子どもを対象とせず、誰からも個人情報を収集しません。

### 10. オープンソース

Tameo はオープンソース（MIT）です。中核機能がネットワーク通信を行わないことを含め、公開ソースコードで確認できます。

### 11. 変更

本ポリシーの更新版はリリースとともに公開し、冒頭に日付を記します。

### 12. 連絡先

ATI株式会社 — https://tameo.ati-mirai.co.jp ・セキュリティ／プライバシー連絡先：tameo@ati-mirai.co.jp
