# Privacy Policy / プライバシーポリシー

_Tameo — macOS clipboard manager by ATI Inc. (ATI株式会社)_

**Last updated: 2026-07-17**

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

### 4. How monitoring works

Tameo polls the pasteboard's **change counter**, which says only "something changed" and reveals nothing about the contents.

When it sees a change, Tameo first inspects **only the _type_ of data** on the pasteboard (e.g. "there is text") and decides whether the item should be saved at all. Concealed, temporary and auto-generated items, copies from your excluded apps, and data types you turned off are all filtered out at this stage — **before any content is read**.

If the item passes those checks, Tameo reads it and saves it to your local history at that moment. This is inherent to what a clipboard manager does: history has to be captured when you copy, because by the time you open the history the pasteboard has already moved on.

Every content read goes through **exactly one place** in the source code ([`ClipboardMonitor`](Tameo/Services/ClipboardMonitor.swift)), so it can be audited. Nothing that is read is transmitted anywhere.

### 5. Excluded data

- **Concealed / sensitive items.** Items flagged as concealed (`org.nspasteboard.ConcealedType`) by password managers are **never saved**, and this cannot be turned off.
- Temporary and auto-generated items are always skipped, and this cannot be turned off either.
- **Excluded apps.** You can exclude specific apps so that what you copy from them is not recorded. When the copying app declares itself (`org.nspasteboard.source`) Tameo uses that; otherwise it identifies the source by which app was frontmost around the copy, and when that is ambiguous it errs toward **not** saving.

### 6. Accessibility permission

Tameo asks for macOS **Accessibility** permission for a single purpose: to synthesize a ⌘V keystroke to paste the item you selected into the app you were using. It does **not** read your screen, observe other apps, or log keystrokes.

### 7. Network access

Tameo's core features work **fully offline**. The only network activity is the **automatic update check** via Sparkle: the app contacts ATI's update feed to see whether a newer version exists. Sparkle asks on first launch whether you want automatic updates, and you can change or disable this at any time. As with any download, the check reveals your IP address and the app version to the update server — but **no clipboard data, personal data, or identifiers are sent**.

### 8. Data retention and deletion

History is capped at the number of items you configure; older items are removed automatically. You can delete a single item from the history palette with **⌘⌫**, or clear the whole history from the menu bar.

**Removing the app does not remove your history.** macOS leaves application data in place when you drag an app to the Trash. To delete Tameo's data as well, remove this folder:

```
~/Library/Application Support/Tameo/
```

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

### 4. 監視のしくみ

Tameo はペーストボードの**変更カウンタ**を監視します。これは「何か変わった」ことしか示さず、中身については何も明かしません。

変化を検知すると、まずペーストボード上の**「種別」だけ**を調べ（例：「テキストがある」）、その項目をそもそも保存すべきかを判定します。機密／一時／自動生成の項目、除外アプリからのコピー、あなたがオフにした種別は、この段階で—— **中身を一切読む前に** ——除外されます。

この判定を通った項目は、その時点で読み取って端末内の履歴へ保存します。これはクリップボードマネージャの性質上避けられません。履歴はコピーした瞬間に捉える必要があり、あなたが履歴を開く頃にはペーストボードの中身は既に次のものへ入れ替わっているからです。

内容の読み取りはソースコード上の**ただ 1 箇所**（[`ClipboardMonitor`](Tameo/Services/ClipboardMonitor.swift)）に集約してあり、検証できます。読み取った内容がどこかへ送信されることはありません。

### 5. 保存しないデータ

- **機密項目**：パスワードマネージャ等の機密フラグ（`org.nspasteboard.ConcealedType`）付き項目は**決して保存しません**。これは設定で無効化できません。
- 一時／自動生成データも常にスキップします。同じく無効化できません。
- **除外アプリ**：指定したアプリからコピーした内容は記録しません。コピー元アプリが自身を明示している場合（`org.nspasteboard.source`）はそれを使い、無い場合はコピー前後に前面だったアプリで判定します。判別が曖昧なときは**保存しない**側に倒します。

### 6. アクセシビリティ権限

macOS の**アクセシビリティ**権限は、選んだ項目を直前のアプリへ貼り付けるための ⌘V 合成のみに使います。画面の読み取り・他アプリの監視・キーロギングには使いません。

### 7. ネットワーク

中核機能は**完全オフライン**で動作します。唯一の通信は**自動アップデート確認**（Sparkle）です：ATI のアップデートフィードへ新バージョンの有無を確認します。初回起動時に Sparkle が自動更新の可否を尋ね、後からいつでも変更・無効化できます。一般的なダウンロードと同様 IP とバージョンが伝わりますが、**クリップボードのデータ・個人情報・識別子は一切送信しません**。

### 8. 保持と削除

履歴は設定件数で上限管理され、古い項目は自動削除されます。個別の項目は履歴パレットで **⌘⌫**、全消去はメニューバーから行えます。

**アプリを削除しても履歴は消えません。** macOS はアプリをゴミ箱へ入れてもアプリのデータを残すためです。データも消すには、次のフォルダを削除してください：

```
~/Library/Application Support/Tameo/
```

### 9. 子どもについて

Tameo は一般的な生産性ツールであり、子どもを対象とせず、誰からも個人情報を収集しません。

### 10. オープンソース

Tameo はオープンソース（MIT）です。中核機能がネットワーク通信を行わないことを含め、公開ソースコードで確認できます。

### 11. 変更

本ポリシーの更新版はリリースとともに公開し、冒頭に日付を記します。

### 12. 連絡先

ATI株式会社 — https://tameo.ati-mirai.co.jp ・セキュリティ／プライバシー連絡先：tameo@ati-mirai.co.jp
