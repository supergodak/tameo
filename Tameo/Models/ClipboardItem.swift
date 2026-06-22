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
    /// 本文のバイト長（UTF-8）。簡易な容量把握用。
    var byteSize: Int = 0

    /// 種別の型付きアクセサ（未知値は .text にフォールバック）。
    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

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
}
