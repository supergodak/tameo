# M3 設計 — データ種別＋プレビュー（画像 / RTF / ファイル / 色 …）

クリーンルーム。Clipy はコード流用せず仕様参照のみ。
設計は並行設計ワークフロー（4領域）→統合→敵対レビューの結果を反映。レビュー判定は **fix-before-implementing**（下記の修正を織り込み済みの版がこのドキュメント）。

## スコープとステージング（ファイルパス最優先で組み替え）

ユーザー最優先要望: **Finder でファイルを Cmd+C → 履歴にパス文字列 → 貼るとパスがテキストで入る（Clipy同等）**。

- **PR-A「土台 + ファイルパス」**: 加法的スキーマ全体 / `CapturedPayload` / `ClipKind.detect`（型集合のみ） / `ContentHash` / `HistoryStore.ingest(_:)`（ハッシュ重複排除＋レガシ backfill） / **自己コピー抑止トークン** / `ClipboardMonitor` チョークポイント書き換え / `PasteService` 種別ディスパッチ / コミット経路 / 固定高 row + leadingSlot。最初に **filename(file URL)** を端から端まで実装（blob無し・サムネ無し・アクター跳躍無しで最小リスク、土台を最速で実証）。テキストは新配線上でそのまま動く。
- **PR-B「画像」**: png/tiff。`ImageThumbnailer`（ImageIO・Data→Data）、`@Attribute(.externalStorage)` の payloadData、Task.detached のサムネ生成＋**changeCount 単調ガードで順序保証**、ThumbnailCache、8MB上限＋truncation＋canonicalBytes フォールバック。
- **PR-C「リッチ＋軽量」**: rtf/rtfd/pdf/url/color。加法的 switch 分岐＋各 PasteService writer＋leadingSlot＋プレーン貼付。

理由: 難所（プライバシー書き換え・Sendable アクター跳躍・SwiftData 移行・重複排除契約）は種別数に依らず土台に集中。最小リスクの filename で土台を実証してから画像の難所を隔離する。スキーマは PR-A で**全種別ぶん**入れるので PR-B/C で再移行不要。

## データモデル（ClipboardItem 加法的・全フィールド既定値付き＝lightweight migration 安全）

既存 `content/createdAt/lastUsedAt/kindRaw/sourceBundleID/isConcealed/byteSize` と既存 `init(content:...)` は不変（テキスト経路はバイト等価）。追加:

```
@Attribute(.externalStorage) var payloadData: Data? = nil   // 画像/rtf/rtfd/pdf の原本（外部ファイル化）
var thumbnailPNG: Data? = nil                                // 小さな縮小PNG（インラインで保持＝行描画でファイルを開かない）
var payloadUTI: String = "public.utf8-plain-text"
var contentHash: String = ""                                // 小文字hex SHA-256。重複排除の正キー
var pixelWidth: Int = 0
var pixelHeight: Int = 0
var fileURLStrings: String = ""                             // 改行連結の絶対パス（非ファイルは空）
var colorHex: String = ""
var payloadTruncated: Bool = false
```

`content` は種別ごとの**表示＋検索＋貼付ラベル**文字列に再定義（text=本文そのまま / url=URL / filename=パス（複数は改行連結 or "name (+N more)"） / color=`#FF8800` / image=`Image · 1200×800 · PNG` / rtf=平文化 / pdf=`PDF · N pages`）。text 経路は `content`=本文で完全不変。

新 designated `init(payload: CapturedPayload, contentHash: String)` を追加。convenience `var fileURLs: [URL]`。

## CapturedPayload（アクター境界を越える唯一の Sendable 構造体）

`Tameo/Services/CapturedPayload.swift`（新規）。値型のみ（NSImage/CGImage を**絶対に含めない**）。`kind / content / payloadUTI / canonicalBytes / payloadData? / thumbnailPNG? / pixelWidth / pixelHeight / fileURLStrings / colorHex / payloadTruncated / sourceBundleID? / isConcealed / byteSize`。`canonicalBytes` = 重複排除ハッシュの入力（text/url/filename/color は `content` の UTF-8、png/tiff/rtf/rtfd/pdf は payloadData）。`static func text(_:source:)`、`withThumbnail(_:)`。

## ClipKind.detect — 型集合のみで判定（プライバシー HIGH 修正）

`static func detect(types: Set<NSPasteboard.PasteboardType>) -> ClipKind`。**中身を読まず**、監視ループが既に集めている型集合だけで分類。richest/most-specific-first:
`filename(.fileURL) → url(.URL 非file) → color(NSColor型) → pdf → rtfd → rtf → png → tiff → text(.string)`。
`var preferredUTI`、`var hasBinaryPayload`。色は **NSColor 型のみ**で検知（平文中の `#FF8800` は誤検知回避のため対象外）。`readObjects` の投機的多重実行は禁止——勝った1型だけを `data(forType:)`/`string(forType:)` で**1回**読む。

## 自己コピー抑止トークン（CRITICAL 修正 — 再取り込みハッシュ一致契約を置換）

問題: 貼り戻し時 PasteService が rich＋`.string` を書く→次tickで監視が rich を再検知し再取り込み。だが書き戻しバイトは AppKit により正規化され**原本と不一致**→毎回重複行（color/filename も NSColor.write/NSURL.write で再シリアライズされ不一致）。

解決: **Tameo 自身が生成した `changeCount` を監視が1回だけスキップ**する。
- 共有 `@MainActor` ゲート（例: `PasteboardWriteGate { var lastSelfWriteChangeCount: Int? }`）を PasteService と ClipboardMonitor に注入。
- PasteService は pasteboard 書き込み直後に `NSPasteboard.general.changeCount` をゲートへ記録。
- ClipboardMonitor.tick: `change == gate.lastSelfWriteChangeCount` なら ingest せず `lastChangeCount` 更新のみ。
- 順序用に `markUsed` は維持（lastUsedAt の bump）。これで text 含め全種別で重複が原理的に出ず、バイト等価性に依存しない。
- 外部アプリで偶然同一内容をコピーした場合はトークン不一致→正常に ingest され、ハッシュ重複排除が処理。

## HistoryStore.ingest(_ payload:)

`guard !isConcealed; guard byteSize > 0; let hash = sha256Hex(canonicalBytes)`。最新行取得。**レガシ backfill**: 最新行の `contentHash` が空なら `sha256Hex(payloadData ?? Data(content.utf8))` で補完してから比較（アップグレード後の初回再コピー欠落を全移行なしで塞ぐ）。一致なら `lastUsedAt=.now; save()`。不一致なら `ClipboardItem(payload:contentHash:)` を insert→prune→save。既存 `ingest(text:...)` は `CapturedPayload.text(...)` を作って `ingest(_:)` を呼ぶ薄いラッパへ。`newestItem()/prune()/save()/markUsed()/clearAll()` 不変。
- truncated/binary の canonicalBytes は payloadData が nil の時 **thumbnailPNG にフォールバック**（空 Data の SHA 定数衝突を回避）。`byteSize` は truncation 前の原本サイズ。

## ClipboardMonitor チョークポイント書き換え（プライバシー厳守）

`changeCount` のみで変化検知、`ignoredMarkerTypes` 除外ループは**データ読み取り前**に従来どおり。唯一の背景読み取り `classify(_ items:, source:) -> CapturedPayload?` に置換: まず型集合で `ClipKind.detect`→勝った1型だけ読む。filename は `string(forType:.fileURL)`/`data(forType:.fileURL)` を優先（readObjects 多重実行しない）。`source` = `org.nspasteboard.source`（無ければ `NSWorkspace.frontmostApplication?.bundleIdentifier`、長さ256上限・bundle id 検証、**concealed 判定には使わない**・助言のみ）。画像のみ raw Data を main で取得→`Task.detached(.utility){ thumb = ImageThumbnailer.thumbnailPNG(...); pixelSize も同タスク内で1回; await store.ingest(payload.withThumbnail(thumb)) }`。**画像 ingest は source changeCount で単調ガード**（古い結果が新しい結果の後に着地しない）。非画像は main でそのまま ingest。NSImage/CGImage はここで構築しない。

## PasteService 種別ディスパッチ＋プレーン貼付

`copyToPasteboard(_ item:)` は `clearContents()` 後 `item.kind` で分岐し**勝ち型のネイティブ＋種別別フォールバック**を書く（書き込み直後に抑止トークンをゲートへ記録）:
- text→`setString(content)` / png,tiff→`setData(payloadData, .png/.tiff)`（**ラベル文字列は .string に書かない**——`Image · …` を貼るのは無より悪い） / rtf,rtfd→`setData(payloadData,…)`＋`.string`=**平文化（`content`）** / pdf→`setData(payloadData,.pdf)` / filename→`NSURL(fileURLWithPath:).write` ＋ `.string`=パス / url→`NSURL(string:).write` ＋ `.string`=URL / color→`NSColor.write` ＋ `.string`=hex。
- payloadData が nil/empty（externalStorage 欠落/truncated）の binary は `.string` フォールバックへ。画像で平文不可ならラベルは書かず data のみ。
- `copyAsPlainText(_ item:)` は **`.string` のみ**。rtf/rtfd は再デコードせず**事前計算済み `content`（平文化）を使用**（メインアクターでの再デコード stutter 回避）。png/tiff/pdf は通常の rich 貼付へフォールバック（⌥でも無音 no-op にしない）。
- `paste(_ item:, asPlainText:, to:)`: 分岐後、既存の changeCount ガード→target ガード→アクセシビリティ→activate→Sauce ⌘V を**そのまま**（合成は種別非依存）。

## 行描画（Decade Pager・固定高厳守）

`rowContentHeight=22 / leadingSize=20`。`row(index:item:)` は Button アクション・badge・選択ハイライト・hit-area を**現状と pixel 等価**に維持。label 内は1つの `HStack(spacing:8).frame(height: rowContentHeight)`: badge / `leadingSlot(...).frame(width:20,height:20).clipped()` / `Text(item.content).lineLimit(1)` / 任意 trailingChip（`.fixedSize` で高さ固定）。`leadingSlot` は `item.kind` 分岐: text→`Color.clear`（M2 と同一外観）/ image,pdf→thumbnailPNG を ThumbnailCache 経由 `Image(nsImage:)` else SF Symbol / color→スウォッチ / **filename→ingest 時に解決した file icon（thumbnailPNG に格納）**、行 body 内では `NSWorkspace.icon(forFile:)` を**呼ばない**（main スレッド disk hit でページングが jank する）/ url→`link` / rtf,rtfd→`textformat`＋'RTF' chip。行は `item.kind/content/thumbnailPNG` のみ参照（payloadData を絶対に触らない）。
- 縦予算を明示計算: `440 − header − dividers − footer (− banner)` が `10 × 行高` を収めること。**アクセシビリティ banner 表示時（最悪ケース）**も含む #Preview で 10 行同一高・行10非クリップを検証。

## 採用済み既定値（先送り判断、PR-B/C で再確認可）

- blob 上限 = **8 MB**（超過は payloadData 破棄・thumbnail/metadata/hash 保持・`payloadTruncated=true`・content にラベル）
- サムネ最長辺 = **128 px**
- プレーン貼付トリガ = **単独 ⌥ + 数字 / ⌥ + Return / ⌥-click**（⌥ は未使用で衝突無し、footer に条件付きヒント）
- 色検知 = **NSColor 型のみ**
- 複数ファイル = **改行連結のパス**（既定は全パス。貼付は先頭ファイルを NSURL＋全パスを `.string`）
- ファイル貼付の既定表現 = **パス文字列**（ユーザー優先）。実ファイル参照も併せ持ち「実ファイルとして貼る」は後日トグル可

## 敵対レビュー対応チェックリスト（実装時に必ず満たす）

- [ ] CRITICAL 再取り込み重複 → **抑止トークン**で置換（バイト等価依存を撤廃）
- [ ] HIGH プライバシー → 型集合判定→勝ち型1回読み。`readObjects` 多重禁止。filename は `*forType:.fileURL`
- [ ] HIGH アクター順序 → 画像 ingest を changeCount 単調ガード。pixelSize は detached 内で1回
- [ ] HIGH 移行 → **PR-A マージ前に M2 実ストア（テキストのみ）で開通テスト**（破壊的再生成しない/レガシ行 nil 既定/新画像行が sidecar 生成）。推論失敗時は lightweight SchemaMigrationPlan
- [ ] HIGH 平文フォールバック → 画像はラベルを `.string` に書かない。rtf は平文 content を使用（kind 別ルール）
- [ ] MEDIUM truncated 画像のハッシュ → canonicalBytes を thumbnailPNG にフォールバック。byteSize は原本サイズ
- [ ] MEDIUM list 再順序 → 抑止トークンで解消（markUsed は順序用のみ）
- [ ] MEDIUM 行高 → 全 leadingSlot を 20×20 固定、trailingChip 高さ固定、banner 表示込みで縦予算検証
- [ ] MEDIUM file icon → ingest 時に解決し thumbnailPNG 格納、行 body は純キャッシュ参照
- [ ] LOW source 長さ256上限・bundle id 検証・助言のみ
- [ ] LOW copyAsPlainText は事前計算 content 使用。画像/pdf の ⌥ は rich へフォールバック
- [ ] NIT detect は `ClipKind+Detection.swift`(AppKit) へ分離し ClipKind.swift を Foundation-only に保つ
```
