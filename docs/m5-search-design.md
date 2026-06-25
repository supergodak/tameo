# M5 — 履歴検索 ＋ ピン留め ＋ 種別フィルタ（設計）

Clipy 相当で止まらず、Tameo ならではの価値を出すための M5。土台＝履歴検索、その上にオンデバイスの差別化（画像OCR検索ほか）を載せる。

## 北極星

ローカル完結 × 日本語ファースト × Apple Silicon の計算資源を活かしたオンデバイスの賢さ。クラウドに送らないからこそ価値が出る方向。

## スコープ（このM5）

- 履歴検索（インクリメンタル）
- ピン留め／お気に入り（最上段固定・prune から保護）
- 種別フィルタ（チップ）
- 画像OCRテキストは「検索インデックスへ連結するフック」だけ用意し、本実装は後続

## アーキテクチャの前提（既存コードの読み取り結果）

- パレットは `@Query` 駆動ではなく **`PaletteModel.rows` のスナップショット駆動**。`HistoryPanelController.show()` で `FetchDescriptor` を1回引いて `[PaletteRow]` に固める。
- 番号キー 1–0・Decade Pager・フッタ件数・キー操作はすべて `model.rows` から導出。→ **絞り込みで `rows` を作り直せば、番号貼付やページャは自動で「絞り込み後の並び」に追従**（追加配線ほぼ不要）。
- キー入力は `NSEvent.addLocalMonitorForEvents`（SwiftUI focus ではない）。検索フィールドは**フォーカスを奪う実TextFieldを置かず**、`model.query` を表示するだけの疑似フィールドにして、入力は既存モニタで拾う（フォーカス争い＆resignKey自動クローズを回避）。

## 検索の正規化（日本語ファースト）

保存時に正規化済みインデックス文字列を**1回だけ計算してキャッシュ**（毎キーストロークの再計算を避ける）。規則（順序が意味を持つ）:

1. NFKC 互換正規化（全角ＡＢＣ１２３→ABC123、半角ｶﾅ→カナ）
2. カタカナ→ひらがな畳み込み（カナ/かな の表記ゆれ吸収）
3. 小文字化
4. 連続空白の圧縮＋トリム

実装は `Tameo/Services/SearchNormalizer.swift`。検索時はクエリを同じ `normalize` に通して `searchIndex.contains(query)`（部分一致）。ファジーは将来フック。

索引の元テキストは本文＋色hex＋ファイルパス（`#2D7DD2` や `/Users/...` でも引ける）。巨大本文は先頭8KBで打ち切り。

## データモデル変更（`ClipboardItem`）

- `var searchIndex: String = ""`（空＝レガシ行。初回検索/起動で backfill）
- `var isPinned: Bool = false`
- すべて既定値付き＝SwiftData lightweight migration 安全（スキーマ版上げ不要）。
- backfill：`HistoryStore.backfillSearchIndexIfNeeded()`（起動時1回・UserDefaults でガード）＋ `ensureSearchIndex(_:)`（表示直前の遅延補完）。

## 番号キーのUX（確定: 文脈ルール＋`/`エスケープ）

- 検索が**空**のあいだ：`1`〜`0` は従来どおり**貼り付け**（開いて即・番号で貼る速さを維持）
- 検索を**打ち始めたら**：以降の数字は**クエリに入る**
- 数字始まりの検索：`/`（または `⌘F`）で検索モードに入ると、数字も全部クエリに入る
- `ESC`：クエリ／種別フィルタがあればクリア、無ければ従来の挙動（スニペット戻り／hide）
- 貼り付けは選択行で `Return`、`⌥+数字` の平文貼付は維持

## ピン留め

- `HistoryStore.setPinned(_:_:)`、`prune()` はピンを削除対象から除外。
- 表示はピン最上段固定（別セクションにせず、ページャ計算を壊さないため pinned-first の単一リスト）。`rowView` に `pin.fill` 表示。

## 種別フィルタ

- `ClipKind` に `displayName` / `symbolName` を追加（チップ用、`historyLeading` のSF Symbolsと一貫）。
- チップで `model.typeFilter: Set<ClipKind>`（空＝全部）をトグル。テキスト検索とAND。

## コミット分割

1. `searchIndex` ＋ `SearchNormalizer` ＋ backfill（UIなし）← 完了
2. `isPinned` ＋ `setPinned` ＋ prune保護
3. `PaletteModel` 絞り込みリファクタ（`allRows`＋導出 `rows`、pinned-first）
4. キー処理（タイピング→クエリ／`/`モード／ESCクリア／ピンキー）
5. UI（疑似検索フィールド・種別チップ・ピン表示・凡例・空状態・`baseHeight`増）
6. 起動時の一括 backfill 呼び出し

## OCR検索PoC（B）の結果メモ

Vision の `VNRecognizeTextRequest`（`recognitionLanguages = ["ja-JP","en-US"]`, `.accurate`）をオンデバイスで検証。

- 合成画像（全角・かな・URL・色・メール混在）：漢字／URL／色hex／メール／電話は完全一致。**全角ＡＢＣ１２３→ABC123 に自動正規化**され、こちらのNFKC検索と一致。
- 低解像度の実スクショ（372x338）でも日本語UI文言を全行正しく認識。
- 速度 200〜450ms/枚。取り込み時に**非同期OCR**すれば体感ゼロ。
- 結論：「スクショをコピー→中の文字で検索／テキストとして貼る」は実用に足る差別化。`searchIndex` へOCRテキストを連結する形で後続実装。
