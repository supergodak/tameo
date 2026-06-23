import Foundation

/// Clipy のスニペット XML エクスポートを 1 件読み取った結果。
struct ClipyImportedSnippet {
    var title: String
    var content: String
    var enabled: Bool
}

/// Clipy のスニペット XML エクスポートのフォルダ 1 件。
struct ClipyImportedFolder {
    var title: String
    var enabled: Bool
    var snippets: [ClipyImportedSnippet]
}

/// Clipy が書き出すスニペット XML を取り込むパーサ（外部依存なし・Foundation `XMLParser`）。
///
/// Clipy の書き出し形式（`docs/clipy-feature-reference.md` §5）:
/// ```
/// <folders>
///   <folder [enable="true"]>
///     <title>…</title>
///     <snippets>
///       <snippet [enable="true"]>
///         <title>…</title>
///         <content>…</content>
///       </snippet>
///     </snippets>
///   </folder>
/// </folders>
/// ```
/// 要素名で分岐し、`enable` 属性の有無・ネストの細部・CDATA に寛容に作る（Clipy のバージョン差に耐える）。
/// 本文（content）は前後空白を保持し、タイトルのみ trim する。
enum ClipySnippetImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case parseFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "ファイルを読み込めませんでした。"
            case .parseFailed(let m): return "XML の解析に失敗しました: \(m)"
            case .empty: return "スニペットが見つかりませんでした（Clipy のスニペット XML を選んでください）。"
            }
        }
    }

    static func parse(data: Data) throws -> [ClipyImportedFolder] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.parseFailed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard !delegate.folders.isEmpty else { throw ImportError.empty }
        return delegate.folders
    }

    static func parse(url: URL) throws -> [ClipyImportedFolder] {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        return try parse(data: data)
    }

    // MARK: - XMLParserDelegate

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var folders: [ClipyImportedFolder] = []
        private var curFolder: ClipyImportedFolder?
        private var curSnippet: ClipyImportedSnippet?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch elementName.lowercased() {
            case "folder":
                curFolder = ClipyImportedFolder(
                    title: "", enabled: boolAttr(attributeDict, "enable", default: true), snippets: [])
            case "snippet":
                curSnippet = ClipyImportedSnippet(
                    title: "", content: "", enabled: boolAttr(attributeDict, "enable", default: true))
            case "title", "content":
                // リーフ収集の開始時にだけバッファをリセットする。リーフ内に子要素（手編集や別ツール由来の
                // 生マークアップ）が現れても、その開始でリセットしないことで手前のテキスト欠落を防ぐ
                // （インラインタグは無視され、囲まれたテキストだけが残る）。
                buffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName.lowercased() {
            case "title":
                // <title> は snippet にも folder にも現れる。snippet 進行中ならそちら、無ければ folder。
                if curSnippet != nil {
                    curSnippet?.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if curFolder != nil {
                    curFolder?.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "content":
                curSnippet?.content = buffer   // 本文は trim しない（意図的な前後空白を保持）
            case "snippet":
                if let s = curSnippet { curFolder?.snippets.append(s) }
                curSnippet = nil
            case "folder":
                if let f = curFolder { folders.append(f) }
                curFolder = nil
            default:
                break
            }
            // バッファは次のリーフ（title/content）開始時にリセットするため、ここでは消さない。
            // 要素間の空白は次のリーフ開始でクリアされるので蓄積しても無害。
        }

        private func boolAttr(_ dict: [String: String], _ key: String, default def: Bool) -> Bool {
            guard let v = dict[key]?.lowercased() else { return def }
            return v == "true" || v == "1" || v == "yes"
        }
    }
}
