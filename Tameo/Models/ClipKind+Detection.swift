import AppKit

/// 種別判定とペースト用メタ。
/// `ClipKind` enum 本体は Foundation-only に保つため、AppKit 依存のここに分離する。
/// `detect` は **型集合のみ** で判定し中身を読まない（プライバシー: 背景読み取りを増やさない）。
extension ClipKind {
    /// pasteboard 型集合から種別を判定（richest / most-specific first）。中身は読まない。
    static func detect(types: Set<NSPasteboard.PasteboardType>) -> ClipKind {
        if types.contains(.fileURL) { return .filename }
        if types.contains(.URL) { return .url }
        if types.contains(.color) { return .color }
        if types.contains(.pdf) { return .pdf }
        if types.contains(.rtfd) { return .rtfd }
        if types.contains(.rtf) { return .rtf }
        if types.contains(.png) { return .png }
        if types.contains(.tiff) { return .tiff }
        return .text
    }

    /// この種別を貼り戻すときの主要 UTI 文字列。
    var preferredUTI: String {
        switch self {
        case .text: return "public.utf8-plain-text"
        case .url: return "public.url"
        case .filename: return "public.file-url"
        case .color: return "com.apple.cocoa.pasteboard.color"
        case .pdf: return "com.adobe.pdf"
        case .rtf: return "public.rtf"
        case .rtfd: return "com.apple.flat-rtfd"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        }
    }

    /// 原本バイナリ（externalStorage）を持つ種別か。重複排除の canonicalBytes 選択に使う。
    var hasBinaryPayload: Bool {
        switch self {
        case .png, .tiff, .rtf, .rtfd, .pdf: return true
        default: return false
        }
    }
}
