import Foundation

/// Clipy のスニペット XML エクスポートを 1 件読み取った結果。
struct ClipyImportedSnippet: Sendable {
    var title: String
    var content: String
    var enabled: Bool
}

/// Clipy のスニペット XML エクスポートのフォルダ 1 件。
struct ClipyImportedFolder: Sendable {
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

    // MARK: - 取り込み上限
    //
    // ユーザーが明示的に選んだファイルしか通らない経路なので攻撃面は狭いが、巨大／細工された XML で
    // メモリを食い潰したり長時間固まったりするのは防ぐ。Clipy の実エクスポートは通常数十 KB なので、
    // どの上限も現実の利用では当たらない余裕を持たせてある。

    /// 取り込む XML ファイルの上限バイト数。読み込む**前**に弾く（ファイルはサイズを事前に問い合わせできる）。
    static let maxFileBytes = 32 * 1024 * 1024
    /// フォルダ数の上限。
    static let maxFolders = 1_000
    /// スニペット総数の上限。
    static let maxSnippets = 50_000
    /// タイトル・本文 1 件あたりの上限文字数（UTF-8 バイト）。
    static let maxTextBytes = 1024 * 1024

    enum ImportError: LocalizedError {
        case unreadable
        case parseFailed(String)
        case tooLarge(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "ファイルを読み込めませんでした。"
            case .parseFailed(let m): return "XML の解析に失敗しました: \(m)"
            case .tooLarge(let m): return "ファイルを取り込めません: \(m)"
            case .empty: return "スニペットが見つかりませんでした（Clipy のスニペット XML を選んでください）。"
            }
        }
    }

    static func parse(data: Data) throws -> [ClipyImportedFolder] {
        guard data.count <= maxFileBytes else {
            throw ImportError.tooLarge("XML が大きすぎます（\(data.count / 1_048_576)MB > \(maxFileBytes / 1_048_576)MB）")
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            // 上限超過による中断は、XML の構文エラーと区別して理由を返す。
            if let overflow = delegate.overflow { throw ImportError.tooLarge(overflow) }
            throw ImportError.parseFailed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard !delegate.folders.isEmpty else { throw ImportError.empty }
        return delegate.folders
    }

    static func parse(url: URL) throws -> [ClipyImportedFolder] {
        // サイズは読み込む前に問い合わせる（`NSPasteboard` と違い、ファイルは事前に分かる）。
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else {
            throw ImportError.tooLarge("ファイルが大きすぎます（\(size / 1_048_576)MB > \(maxFileBytes / 1_048_576)MB）")
        }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        return try parse(data: data)
    }

    // MARK: - XMLParserDelegate

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var folders: [ClipyImportedFolder] = []
        /// 上限超過で中断したときの理由（構文エラーと区別するため）。
        private(set) var overflow: String?
        private var curFolder: ClipyImportedFolder?
        private var curSnippet: ClipyImportedSnippet?
        private var buffer = ""
        private var snippetCount = 0

        /// 上限を超えたら解析を打ち切る。`buffer` は無制限に伸びるため、放置すると
        /// 単一の巨大 `<content>` だけでメモリを食い潰せる。
        private func fail(_ reason: String, _ parser: XMLParser) {
            overflow = reason
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch elementName.lowercased() {
            case "folder":
                guard folders.count < ClipySnippetImporter.maxFolders else {
                    return fail("フォルダ数が上限（\(ClipySnippetImporter.maxFolders)）を超えました", parser)
                }
                curFolder = ClipyImportedFolder(
                    title: "", enabled: boolAttr(attributeDict, "enable", default: true), snippets: [])
            case "snippet":
                guard snippetCount < ClipySnippetImporter.maxSnippets else {
                    return fail("スニペット数が上限（\(ClipySnippetImporter.maxSnippets)）を超えました", parser)
                }
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
            guard buffer.utf8.count + string.utf8.count <= ClipySnippetImporter.maxTextBytes else {
                return fail("タイトルまたは本文が長すぎます（上限 \(ClipySnippetImporter.maxTextBytes / 1024)KB）", parser)
            }
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard buffer.utf8.count + CDATABlock.count <= ClipySnippetImporter.maxTextBytes else {
                return fail("タイトルまたは本文が長すぎます（上限 \(ClipySnippetImporter.maxTextBytes / 1024)KB）", parser)
            }
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
                if let s = curSnippet {
                    curFolder?.snippets.append(s)
                    snippetCount += 1
                }
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
