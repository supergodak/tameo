import Foundation
import SwiftData
import Observation

/// スニペット（フォルダ／定型文）の唯一の書き込み主体。すべて MainActor 上で動く。
/// `HistoryStore` と対称：View からの直叩き（insert/delete/save）を禁止し、書き込みをここへ一本化する。
/// order は D&D／移動後に 0..n の密連番へ再採番する。SwiftData の to-many は順序非保証ゆえ、
/// 取り出しは常に `order` 昇順でソートする（`SnippetFolder.orderedSnippets` 経由）。
@MainActor
@Observable
final class SnippetStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Fetch

    /// 全フォルダ（order 昇順）。編集UI用。
    func allFolders() -> [SnippetFolder] {
        let d = FetchDescriptor<SnippetFolder>(sortBy: [SortDescriptor(\.order)])
        return (try? modelContext.fetch(d)) ?? []
    }

    /// パレット呼び出し用：有効なフォルダのみ（order 昇順）。
    func enabledFolders() -> [SnippetFolder] {
        allFolders().filter { $0.enabled }
    }

    // MARK: - Folder CRUD

    @discardableResult
    func addFolder(title: String) -> SnippetFolder {
        // 末尾 order + 1（allFolders は order 昇順なので last が最大）。
        let nextOrder = (allFolders().last?.order ?? -1) + 1
        let folder = SnippetFolder(title: title, order: nextOrder)
        modelContext.insert(folder)
        save()
        return folder
    }

    func renameFolder(_ folder: SnippetFolder, title: String) {
        folder.title = title
        save()
    }

    func setFolderEnabled(_ folder: SnippetFolder, _ enabled: Bool) {
        folder.enabled = enabled
        save()
    }

    func deleteFolder(_ folder: SnippetFolder) {
        modelContext.delete(folder)   // cascade で配下 Snippet も削除
        save()
    }

    // MARK: - Snippet CRUD

    @discardableResult
    func addSnippet(to folder: SnippetFolder, title: String = "", content: String = "") -> Snippet {
        let nextOrder = (folder.orderedSnippets.last?.order ?? -1) + 1
        let snippet = Snippet(title: title, content: content, order: nextOrder)
        snippet.folder = folder
        modelContext.insert(snippet)
        save()
        return snippet
    }

    func updateSnippet(_ snippet: Snippet, title: String, content: String) {
        snippet.title = title
        snippet.content = content
        save()
    }

    func setSnippetEnabled(_ snippet: Snippet, _ enabled: Bool) {
        snippet.enabled = enabled
        save()
    }

    func deleteSnippet(_ snippet: Snippet) {
        modelContext.delete(snippet)
        save()
    }

    // MARK: - Import（Clipy XML 取り込み）

    /// Clipy からインポートしたフォルダ群を末尾に**追加**する（既存は破壊しない）。
    /// 戻り値は作成した (フォルダ数, スニペット数)。タイトル空のスニペットは本文先頭行から補完する。
    @discardableResult
    func importClipyFolders(_ imported: [ClipyImportedFolder]) -> (folders: Int, snippets: Int) {
        var folderCount = 0, snippetCount = 0
        var nextFolderOrder = (allFolders().last?.order ?? -1) + 1

        for impFolder in imported {
            let title = impFolder.title.isEmpty ? "Imported" : impFolder.title
            let folder = SnippetFolder(title: title, order: nextFolderOrder, enabled: impFolder.enabled)
            nextFolderOrder += 1
            modelContext.insert(folder)
            folderCount += 1

            for (i, impSnippet) in impFolder.snippets.enumerated() {
                let snipTitle = impSnippet.title.isEmpty
                    ? Self.deriveTitle(from: impSnippet.content)
                    : impSnippet.title
                let snippet = Snippet(title: snipTitle, content: impSnippet.content,
                                      order: i, enabled: impSnippet.enabled)
                snippet.folder = folder
                modelContext.insert(snippet)
                snippetCount += 1
            }
        }
        save()
        return (folderCount, snippetCount)
    }

    // MARK: - Export（Clipy 互換 XML 書き出し。往復可能）

    /// 全フォルダ／スニペットを Clipy のスニペット XML 形式で書き出す（`ClipySnippetImporter` と往復可能）。
    func exportClipyXML() -> String {
        // XML 1.0 で不正な制御文字（タブ/改行/復帰 以外の C0）を落としてから &<> をエンティティ化する。
        // これを欠くと、ターミナル出力等の制御文字を含む本文を書き出した XML が importer で全件パース失敗する。
        func esc(_ s: String) -> String {
            let cleaned = String(s.unicodeScalars.filter {
                $0.value == 0x9 || $0.value == 0xA || $0.value == 0xD || $0.value >= 0x20
            })
            return cleaned
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<folders>\n"
        for folder in allFolders() {
            // enable 属性を出力して往復で有効/無効フラグを保持する（importer は属性欠如を true 扱い）。
            xml += "  <folder enable=\"\(folder.enabled)\">\n    <title>\(esc(folder.title))</title>\n    <snippets>\n"
            for snippet in folder.orderedSnippets {
                xml += "      <snippet enable=\"\(snippet.enabled)\">\n        <title>\(esc(snippet.title))</title>\n"
                xml += "        <content>\(esc(snippet.content))</content>\n      </snippet>\n"
            }
            xml += "    </snippets>\n  </folder>\n"
        }
        xml += "</folders>\n"
        return xml
    }

    /// タイトル未設定スニペットの表示名を本文の最初の非空行から導出（最大40文字）。
    /// 先頭が空行でも、その下に実テキストがあればそれを採用する。
    private static func deriveTitle(from content: String) -> String {
        let firstNonEmpty = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstNonEmpty.isEmpty ? "Untitled" : String(firstNonEmpty.prefix(40))
    }

    // MARK: - Reorder（D&D 後の表示順配列を受け取り 0..n へ密連番再採番）

    func reorderFolders(_ folders: [SnippetFolder]) {
        for (i, f) in folders.enumerated() where f.order != i { f.order = i }
        save()
    }

    func reorderSnippets(_ snippets: [Snippet]) {
        for (i, s) in snippets.enumerated() where s.order != i { s.order = i }
        save()
    }

    // MARK: - Private

    private func save() {
        do {
            try modelContext.save()
        } catch {
            NSLog("Tameo: snippet save failed: %@", String(describing: error))
        }
    }
}
