import Foundation

/// クリップボード項目のデータ種別。
/// M1で使うのは `.text` のみ。残りはストアの `kindRaw` 列を将来互換にするための予約。
enum ClipKind: String, Codable, CaseIterable {
    case text
    case rtf
    case rtfd
    case pdf
    case png
    case tiff
    case filename
    case url
    case color

    /// 画像種別（OCR対象）。
    var isImage: Bool { self == .png || self == .tiff }
}
