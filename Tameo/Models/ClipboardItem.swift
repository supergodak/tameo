import Foundation
import SwiftData

/// クリップボード履歴の1項目。
/// M1ではテキストのみ。追加フィールドは**全てデフォルト値付き**（既存ストアの軽量移行を壊さないため）。
/// M3で画像/RTF/RTFD/PDF/ファイル/URL/色などへ拡張する。
@Model
final class ClipboardItem {
    /// 表示・ペースト対象の本文（M1はテキスト）。
    var content: String = ""
    /// 履歴に追加された日時（不変の作成時刻）。
    var createdAt: Date = Date.now
    /// 最終使用日時。一覧の並び順（新しい順）と「使ったら先頭へ」に使う可変キー。
    var lastUsedAt: Date = Date.now
    /// データ種別の生値（`ClipKind.rawValue`）。M1は常に "text"。
    var kindRaw: String = ClipKind.text.rawValue
    /// コピー元アプリの bundle id（M1では未取得・nil）。
    var sourceBundleID: String?
    /// 機密マーク付きデータか（保存前に弾くので原則 false）。
    var isConcealed: Bool = false
    /// 本文のバイト長（UTF-8、binary は原本サイズ）。簡易な容量把握用。
    var byteSize: Int = 0

    // MARK: - M3 追加（すべて既定値付き＝SwiftData lightweight migration 安全）

    /// 原本バイナリ（画像/rtf/rtfd/pdf）。externalStorage で sidecar 化し行を軽く保つ。M3 PR-B 以降で使用。
    @Attribute(.externalStorage) var payloadData: Data? = nil
    /// 一覧表示用の小さな PNG（画像縮小 or filename のファイルアイコン）。インライン保持で行描画時の disk hit を避ける。
    var thumbnailPNG: Data? = nil
    /// 貼り戻し時の主要 UTI。
    var payloadUTI: String = "public.utf8-plain-text"
    /// 重複排除キー（小文字hex SHA-256）。空＝レガシ行（初回比較時に backfill）。
    var contentHash: String = ""
    /// 画像のピクセル幅・高さ（非画像は 0）。
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// filename の改行連結絶対パス（非ファイルは空）。
    var fileURLStrings: String = ""
    /// 色の #RRGGBB(AA)（非色は空）。
    var colorHex: String = ""
    /// サイズ上限超過で原本を破棄した画像か。
    var payloadTruncated: Bool = false

    /// 種別の型付きアクセサ（未知値は .text にフォールバック）。
    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    /// filename の file URL 配列（`fileURLStrings` は absoluteString 群＝改行分割安全）。
    var fileURLs: [URL] {
        fileURLStrings.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    init(
        content: String,
        createdAt: Date = .now,
        kind: ClipKind = .text,
        sourceBundleID: String? = nil,
        isConcealed: Bool = false
    ) {
        self.content = content
        self.createdAt = createdAt
        self.lastUsedAt = createdAt
        self.kindRaw = kind.rawValue
        self.sourceBundleID = sourceBundleID
        self.isConcealed = isConcealed
        self.byteSize = content.utf8.count
    }

    /// 非テキスト種別を含む取り込み用。`CapturedPayload`（Sendable）から生成する designated init。
    init(payload: CapturedPayload, contentHash: String) {
        self.content = payload.content
        self.createdAt = .now
        self.lastUsedAt = .now
        self.kindRaw = payload.kind.rawValue
        self.sourceBundleID = payload.sourceBundleID
        self.isConcealed = payload.isConcealed
        self.byteSize = payload.byteSize
        self.payloadData = payload.payloadData
        self.thumbnailPNG = payload.thumbnailPNG
        self.payloadUTI = payload.payloadUTI
        self.contentHash = contentHash
        self.pixelWidth = payload.pixelWidth
        self.pixelHeight = payload.pixelHeight
        self.fileURLStrings = payload.fileURLStrings
        self.colorHex = payload.colorHex
        self.payloadTruncated = payload.payloadTruncated
    }
}
