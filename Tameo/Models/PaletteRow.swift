import Foundation
import SwiftData

/// パレットに並べる 1 行の多態。履歴（`ClipboardItem`）/ スニペットフォルダ / スニペット を
/// 同じ Decade Pager（固定高 10 件ページャ）へ通すための統一型。
/// 添字計算・固定高・画面内クランプは行の種類に非依存なので、`PaletteModel` のロジックは
/// `rows: [PaletteRow]` に置換するだけで流用できる。
enum PaletteRow: Identifiable {
    case history(ClipboardItem)
    case folder(SnippetFolder)
    case snippet(Snippet)

    /// ForEach / 選択の安定 id（各モデルの永続 ID）。
    var id: PersistentIdentifier {
        switch self {
        case .history(let item): return item.persistentModelID
        case .folder(let folder): return folder.persistentModelID
        case .snippet(let snippet): return snippet.persistentModelID
        }
    }

    /// 1 行表示の主テキスト。
    var title: String {
        switch self {
        case .history(let item): return item.content
        case .folder(let folder): return folder.title.isEmpty ? "Untitled Folder" : folder.title
        case .snippet(let snippet): return snippet.title.isEmpty ? "Untitled" : snippet.title
        }
    }

    /// 先頭アイコンの種別（`ClipKind` 依存を吸収）。
    var leadingKind: PaletteLeadingKind {
        switch self {
        case .history(let item): return .clip(item.kind)
        case .folder: return .folder
        case .snippet: return .snippet
        }
    }
}

/// 先頭アイコンの分類。`.clip(.text)` のときだけ先頭アイコンを出さない（履歴テキスト＝M2 と同一外観）。
enum PaletteLeadingKind {
    case clip(ClipKind)
    case folder
    case snippet
}

/// パレットの表示ソース。`history` と `snippetFolders` は ⇥ で切り替わるトップ階層、
/// `snippetItems` はフォルダの中身（子階層）。
enum PaletteSource {
    case history
    case snippetFolders
    case snippetItems(SnippetFolder)

    /// SwiftUI の `.id()` 用キー（ソース切替時にクロスフェードを発火させる）。
    var key: String {
        switch self {
        case .history: return "history"
        case .snippetFolders: return "folders"
        case .snippetItems(let f): return "items-\(f.persistentModelID.hashValue)"
        }
    }
}
