import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// 左ペインのツリー選択（フォルダ or スニペットを永続IDで識別）。
enum SnippetSelection: Hashable {
    case folder(PersistentIdentifier)
    case snippet(PersistentIdentifier)
}

/// スニペット編集タブ: 左=フォルダ／スニペットのツリー＋操作ボタン、右=選択項目のエディタ。
/// 書き込みは必ず `SnippetStore` 経由（View 直叩き禁止）。
struct SnippetsSettingsTab: View {
    @Environment(SnippetStore.self) private var store
    @Query(sort: \SnippetFolder.order) private var folders: [SnippetFolder]

    @State private var selection: SnippetSelection?
    @State private var importMessage: String?
    @State private var showImportResult = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Snippets", isPresented: $showImportResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(folders) { folder in
                    folderRow(folder)
                    ForEach(folder.orderedSnippets) { snippet in
                        snippetRow(snippet)
                    }
                }
            }
            Divider()
            sidebarToolbar
        }
    }

    private func folderRow(_ folder: SnippetFolder) -> some View {
        Label(folder.title.isEmpty ? "Untitled Folder" : folder.title, systemImage: "folder")
            .foregroundStyle(folder.enabled ? .primary : .secondary)
            .tag(SnippetSelection.folder(folder.persistentModelID))
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        Label(snippet.title.isEmpty ? "Untitled" : snippet.title, systemImage: "text.quote")
            .foregroundStyle(snippet.enabled ? .primary : .secondary)
            .padding(.leading, 16)
            .tag(SnippetSelection.snippet(snippet.persistentModelID))
    }

    private var sidebarToolbar: some View {
        HStack(spacing: 4) {
            Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                .help("New Folder")
            Button { addSnippet() } label: { Image(systemName: "plus") }
                .help("New Snippet")
                .disabled(targetFolderForNewSnippet == nil)
            Menu {
                Button("Import from Clipy…") { importFromClipy() }
                Button("Export snippets…") { exportSnippets() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Import / Export snippets…")
            Spacer()
            Button { moveSelection(by: -1) } label: { Image(systemName: "chevron.up") }
                .help("Move Up")
                .disabled(selection == nil)
            Button { moveSelection(by: 1) } label: { Image(systemName: "chevron.down") }
                .help("Move Down")
                .disabled(selection == nil)
            Button { deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete")
                .disabled(selection == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .folder(let id):
            if let folder = folders.first(where: { $0.persistentModelID == id }) {
                FolderEditor(folder: folder, store: store).id(id)
            } else { placeholder }
        case .snippet(let id):
            if let snippet = allSnippets.first(where: { $0.persistentModelID == id }) {
                SnippetEditor(snippet: snippet, store: store).id(id)
            } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack {
            Spacer()
            Text("Select a folder or snippet, or create one with the buttons below.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
    }

    // MARK: - Derived

    private var allSnippets: [Snippet] {
        folders.flatMap { $0.orderedSnippets }
    }

    /// 新規スニペットの追加先（選択がフォルダ→それ、スニペット→その親、無選択→先頭フォルダ）。
    private var targetFolderForNewSnippet: SnippetFolder? {
        switch selection {
        case .folder(let id): return folders.first { $0.persistentModelID == id }
        case .snippet(let id): return allSnippets.first { $0.persistentModelID == id }?.folder
        case nil: return folders.first
        }
    }

    // MARK: - Actions

    private func addFolder() {
        let folder = store.addFolder(title: "New Folder")
        selection = .folder(folder.persistentModelID)
    }

    /// Clipy のスニペット XML エクスポートを選んで取り込む（既存は破壊せず末尾に追加）。
    private func importFromClipy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Clipy snippets XML export"
        NSApp.activate()   // runModal 前の前面化保険（設定ウィンドウが既に前面なら no-op）
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folders = try ClipySnippetImporter.parse(url: url)
            let result = store.importClipyFolders(folders)
            // 取り込みは末尾追加（既存は保持）。同じファイルを再度取り込むと重複が増えることを明示する。
            importMessage = "Added \(result.folders) folder(s) and \(result.snippets) snippet(s). Existing snippets were kept."
        } catch {
            importMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        showImportResult = true
    }

    /// 全スニペットを Clipy 互換 XML で書き出す（`importFromClipy` と往復可能）。
    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "snippets.xml"
        panel.message = "Export all snippets as Clipy-compatible XML"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportClipyXML().write(to: url, atomically: true, encoding: .utf8)
            importMessage = "Exported snippets to \(url.lastPathComponent)."
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
        showImportResult = true
    }

    private func addSnippet() {
        guard let folder = targetFolderForNewSnippet else { return }
        let snippet = store.addSnippet(to: folder, title: "New Snippet")
        selection = .snippet(snippet.persistentModelID)
    }

    private func deleteSelection() {
        switch selection {
        case .folder(let id):
            if let folder = folders.first(where: { $0.persistentModelID == id }) {
                store.deleteFolder(folder)
            }
        case .snippet(let id):
            if let snippet = allSnippets.first(where: { $0.persistentModelID == id }) {
                store.deleteSnippet(snippet)
            }
        case nil:
            break
        }
        selection = nil
    }

    /// 選択中の項目を同階層内で上下移動（D&D の代替。同フォルダ内のスニペット、またはフォルダ同士）。
    private func moveSelection(by delta: Int) {
        switch selection {
        case .folder(let id):
            var arr = folders
            guard let idx = arr.firstIndex(where: { $0.persistentModelID == id }),
                  arr.indices.contains(idx + delta) else { return }
            arr.swapAt(idx, idx + delta)
            store.reorderFolders(arr)
        case .snippet(let id):
            guard let snippet = allSnippets.first(where: { $0.persistentModelID == id }),
                  let folder = snippet.folder else { return }
            var arr = folder.orderedSnippets
            guard let idx = arr.firstIndex(where: { $0.persistentModelID == id }),
                  arr.indices.contains(idx + delta) else { return }
            arr.swapAt(idx, idx + delta)
            store.reorderSnippets(arr)
        case nil:
            break
        }
    }
}

// MARK: - Editors

/// 本文の連続編集を集約する保存デバウンス間隔（打鍵ごとの同期 SQLite 保存を避ける）。
private let snippetSaveDebounce: Duration = .milliseconds(400)

/// フォルダのプロパティ編集。@State は init で1回だけ初期化し、ユーザー編集時のみ store へ書き戻す
/// （`.id(folder)` で選択切替時に再生成されるため再読込は不要）。
/// 名前編集は打鍵ごとに保存せずデバウンスし、選択切替/ウィンドウ閉じ（onDisappear）で確実にフラッシュする。
private struct FolderEditor: View {
    let folder: SnippetFolder
    let store: SnippetStore
    @State private var title: String
    @State private var enabled: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var dirty = false

    init(folder: SnippetFolder, store: SnippetStore) {
        self.folder = folder
        self.store = store
        _title = State(initialValue: folder.title)
        _enabled = State(initialValue: folder.enabled)
    }

    var body: some View {
        Form {
            TextField("Folder Name", text: $title)
                .onChange(of: title) { _, new in scheduleSave(title: new) }
            // 有効フラグは低頻度なので即時保存。
            Toggle("Enabled", isOn: $enabled)
                .onChange(of: enabled) { _, new in store.setFolderEnabled(folder, new) }
        }
        .formStyle(.grouped)
        .onDisappear { flush() }
    }

    private func scheduleSave(title: String) {
        dirty = true
        saveTask?.cancel()
        let f = folder, st = store
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: snippetSaveDebounce)
            guard !Task.isCancelled else { return }
            st.renameFolder(f, title: title)
            dirty = false
        }
    }

    /// 保留中の編集を確実に保存（選択切替/閉じ時）。未編集なら何もしない。
    private func flush() {
        saveTask?.cancel()
        guard dirty else { return }
        store.renameFolder(folder, title: title)
        dirty = false
    }
}

/// スニペット本文編集。タイトル＋有効フラグ＋プレーン本文（`TextEditor`）。
/// 本文・タイトルは打鍵ごとに保存せずデバウンスし、選択切替/閉じ（onDisappear）でフラッシュする。
private struct SnippetEditor: View {
    let snippet: Snippet
    let store: SnippetStore
    @State private var title: String
    @State private var content: String
    @State private var enabled: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var dirty = false

    init(snippet: Snippet, store: SnippetStore) {
        self.snippet = snippet
        self.store = store
        _title = State(initialValue: snippet.title)
        _content = State(initialValue: snippet.content)
        _enabled = State(initialValue: snippet.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onChange(of: title) { _, new in scheduleSave(title: new, content: content) }
            // 有効フラグは低頻度なので即時保存。
            Toggle("Enabled", isOn: $enabled)
                .onChange(of: enabled) { _, new in store.setSnippetEnabled(snippet, new) }
            Text("Content")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $content)
                .font(.body.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: content) { _, new in scheduleSave(title: title, content: new) }
        }
        .padding()
        .onDisappear { flush() }
    }

    private func scheduleSave(title: String, content: String) {
        dirty = true
        saveTask?.cancel()
        let s = snippet, st = store
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: snippetSaveDebounce)
            guard !Task.isCancelled else { return }
            st.updateSnippet(s, title: title, content: content)
            dirty = false
        }
    }

    /// 保留中の編集を確実に保存（選択切替/閉じ時）。未編集なら何もしない。
    private func flush() {
        saveTask?.cancel()
        guard dirty else { return }
        store.updateSnippet(snippet, title: title, content: content)
        dirty = false
    }
}
