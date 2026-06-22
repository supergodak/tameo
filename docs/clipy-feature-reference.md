# Clipy 機能リファレンス（Tameo 実装チェックリスト）

> これは Clipy（https://github.com/Clipy/Clipy 、MIT）の**公開リポジトリから抽出した「振る舞い・機能仕様」**の整理です。
> Tameo はクリーンルーム方式で、Clipy のコードは一切流用しません。本書は Clipy の観察可能な機能を
> Tameo 実装の網羅チェックリストとして使うための仕様メモであり、コードの引き写しではありません。
>
> 抽出元: Clipy の設定パネル7枚（General / Menu / Type / Shortcuts / ExcludeApp / Updates / Beta）、
> ローカライズ文字列、`Sources/Services`・`Sources/Models`・`Sources/Managers`。
> 括弧内は Clipy 側の参照ファイル/設定キー（Tameo 実装時の確認用。流用ではない）。

---

## 1. 履歴管理

- 保存できるデータ種別（`PasteboardAvailableType`, `Constants.UserDefaults.storeTypes`）
  - プレーンテキスト / RTF / RTFD / PDF / 画像(TIFF,PNG) / ファイル名(ファイルURL) / URL
  - 種別ごとに保存ON/OFF（Type設定）
- 上限・サイズ（`PasteboardContent`）
  - 最大履歴数 既定 30（`maxHistorySize`、可変）
  - テキストは最大 10,000 文字まで抽出して保存、空文字は保存しない
  - Universal Clipboard 由来の一時ファイルURLは除外
- 重複の扱い（`copySameHistory` / `overwriteSameHistory`）
  - 重複コピーの可否（既定: 有効）
  - 重複時に古い項目を消して先頭へ移動（既定: 有効）
- 機密データ除外（`ignoreConcealedPasteboardType`）
  - `org.nspasteboard.ConcealedType` を保存しない（既定の選択肢として提供）
- スクリーンショット自動取込（Beta: `observerScreenshot`、既定: 無効）

## 2. メニュー / UI

- メニューバーアイコン（`showStatusItem`）: なし / 黒 / 白（既定: 黒）。クリックでメインメニュー
- 履歴メニュー構造（`MenuManager`）
  - インライン表示数（`numberOfItemsPlaceInline`、既定 0）
  - フォルダ分割閾値（`numberOfItemsPlaceInsideFolder`、既定 10）
  - タイトル文字数（`maxMenuItemTitleLength`、既定 20）
  - 先頭に番号付与（`menuItemsAreMarkedWithNumbers`、既定 ON） / 0始まり（`menuItemsTitleStartWithZero`、既定 OFF）
  - 数字キーショートカット（`addNumericKeyEquivalents`、既定 OFF、1〜9）
  - ツールチップ表示（`showToolTipOnMenuItem`、既定 ON / `maxLengthOfToolTip` 既定 200）
  - アイコン表示（`showIconInTheMenu`、既定 ON）
  - サムネイル表示（`showImageInTheMenu`、既定 ON / `thumbnailWidth` 100, `thumbnailHeight` 32）
  - カラーコードプレビュー（`showColorPreviewInTheMenu`、既定 ON、#RRGGBB を色見本表示）
  - 「履歴をクリア」項目の追加（`addClearHistoryMenuItem`、既定 ON）/ クリア前警告（`showAlertBeforeClearHistory`、既定 ON）

## 3. グローバルホットキー（`HotKeyService`, `Shortcuts`設定）

- 修飾キー Cmd / Shift / Ctrl / Alt の自由組合せ + 任意キー
- メイン: ⌘⇧V（`mainKeyCombo`）
- 履歴: ⌘⌃V（`historyKeyCombo`）
- スニペット: ⌘⇧B（`snippetKeyCombo`）
- 履歴クリア: 既定なし（`clearHistoryKeyCombo`）
- スニペットはフォルダ単位の個別ホットキーも割当可

## 4. ペースト挙動（`PasteService`, `AccessibilityService`）

- 選択項目をペーストボードへ → ⌘V を自動入力（`inputPasteCommand`、既定 ON）
- ペースト後に選択項目を先頭へ移動（`reorderClipsAfterPasting`、既定 ON）
- 修飾キー併用の特殊ペースト（Beta → Tameo では正式機能化予定）
  - プレーンテキストで貼る（`pastePlainText`、既定 ON、既定修飾 Cmd）
  - 貼って削除（`pasteAndDeleteHistory`、既定 OFF）
  - 削除のみ（`deleteHistory`、既定 OFF）
- アクセシビリティ許可が必須。未許可時はアラートで誘導

## 5. スニペット（`SnippetRepository`, `CPYSnippetsEditorWindowController`）

- フォルダ / スニペットの CRUD・有効無効・並べ替え（D&D）
- 専用編集ウィンドウ（左ツリー + 右テキストエディタ、プレーンテキスト、Undo/Redo）
- スニペット属性: タイトル / 本文 / 表示順 / 有効フラグ
- フォルダ単位ホットキーで、そのフォルダの有効スニペット一覧をメニュー表示 → 選択でペースト
- XML インポート / エクスポート（`<folders><folder><title/><snippets><snippet><title/><content/></snippet>…`）

## 6. 除外 / プライバシー（`ExcludeAppService`）

- アプリ単位の除外: 前面アプリが対象なら記録しない。NSOpenPanel で `.app` を複数選択追加、Bundle ID で管理
- 機密データ除外（セクション1の ConcealedType）

## 7. General 設定

- ログイン時起動（`loginItem`、既定 OFF）
- 記憶する履歴数（`maxHistorySize`、既定 30）
- ステータスバーアイコン（`showStatusItem`、なし/黒/白）
- 選択後に⌘Vを入力（`inputPasteCommand`、既定 ON）
- 履歴ソート順（最終使用日 / 作成日）
- 重複コピー / 重複上書き（`copySameHistory` / `overwriteSameHistory`）
- ※ クラッシュレポート（Firebase, `collectCrashReport`）→ **Tameo では不採用**（端末内のみ方針）

## 8. Type 設定

- 各データ種別の保存トグル（テキスト/RTF/RTFD/PDF/ファイル名/URL/画像）
- 機密データを無視するトグル

## 9. Shortcuts 設定

- メイン / 履歴 / スニペット / 履歴クリア の各ホットキー録画UI

## 10. ExcludeApp 設定

- 除外アプリ一覧（テーブル）、追加（NSOpenPanel・複数可）、削除、Bundle ID 管理

## 11. Updates 設定（Sparkle）

- 自動更新チェック頻度（毎日/毎週/毎月、既定 毎日） / 自動チェックON/OFF / 今すぐチェック / 最終チェック日時 / 現在バージョン表示

## 12. Beta 設定 → Tameo 方針

- Clipy の「Beta」分類は廃止。有用機能（プレーンテキスト貼付・貼って削除・削除のみ）は**正式機能へ昇格**。
- スクリーンショット自動取込は任意機能として後続検討。

---

## Tameo マイルストーン対応表

- **M1** 履歴の土台: §1(テキストのみ) + §2(基本一覧) — プライバシー対応監視 → SwiftData → メニューバー一覧
- **M2** 取り出して使う: §3 + §4 — ホットキー + 選択ペースト（常用開始の区切り）
- **M3** データ種別: §1(全種別) + §2(サムネイル/色) + §8
- **M4** スニペット: §5
- **M5** 除外/機密: §6
- **M6** 設定網羅: §7 + §9 + §10 + §2(全カスタム項目)（Clipy 同等到達の区切り）
- 配布（フェーズ3）: §11 Sparkle + 署名公証 + Homebrew

## Clipy から変える点（モダン化）

- Realm → **SwiftData** / RxSwift → **Observation / Combine** / Carbon HotKey(Magnet) → **KeyboardShortcuts**(sindresorhus)
- Firebase クラッシュレポート → **不採用**（外部送信ゼロ）
- キーレイアウト処理は **Sauce**(MIT) を流用（自前再実装しない）
