import Foundation
import SwiftData

/// クリップボード履歴の1項目。
/// フェーズ0ではテキストのみ。フェーズ2で画像/RTF/ファイルパス/色などの種別を拡張する。
@Model
final class ClipboardItem {
    /// 表示・ペースト対象のテキスト本文。
    var content: String
    /// 履歴に追加された日時（新しい順表示のソートキー）。
    var createdAt: Date

    init(content: String, createdAt: Date = .now) {
        self.content = content
        self.createdAt = createdAt
    }
}
