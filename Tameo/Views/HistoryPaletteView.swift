import SwiftUI
import SwiftData
import AppKit

/// パレットの寸法。ビュー(`HistoryPaletteView`)とパネル(`HistoryPanelController`)で同じ式を共有し、
/// 両者の高さがズレて隙間/見切れが出ないようにする。
enum PaletteMetrics {
    static let width: CGFloat = 360
    // 440（ヘッダ＋10行＋プレビュー＋フッタ）＋ 56（履歴の検索/種別バー）。
    // 検索バーは履歴ソースでのみ描画され、スニペット時はその分が下部スペースに回るだけで破綻しない。
    static let baseHeight: CGFloat = 496
    /// 権限バナー表示時に縦へ加える分（バナー＋区切り線の高さを上回る値。これで内容が固定高を超えて
    /// 中央寄せ・上下見切れになるのを防ぐ。未許可状態でだけ適用される一時的な増分）。
    static let bannerExtraHeight: CGFloat = 76
    static func height(bannerShown: Bool) -> CGFloat {
        baseHeight + (bannerShown ? bannerExtraHeight : 0)
    }
}

/// ホットキーで開くフローティング・パレット（Decade Pager）。
/// 1ページ=10件(decade)を固定高で表示。履歴・スニペットを同じ行UIに通す（行は `PaletteRow` 多態）。操作:
///   数字 1-9,0 で表示行を確定（フォルダは中へ入る／その他は貼付） / ↑↓ 行移動(端でページ送り) /
///   ←→・[ ] でページ送り / ⇥ で History⇄Snippets 切替 / ⌘1…⌘0 で decade ジャンプ /
///   Return 確定 / Esc 閉じ（スニペット階層では1階層戻る） / クリック確定。
/// キーイベントの捕捉は HistoryPanelController（NSEvent ローカルモニタ）側。ここは表示専任。
struct HistoryPaletteView: View {
    @Environment(PaletteModel.self) private var model

    /// 行確定時（クリック）。
    let onSelect: (PaletteRow) -> Void
    /// アクセシビリティ権限の要求（バナーの「開く」）。
    let onRequestAccessibility: () -> Void

    /// サムネ NSImage のメモ化（行 body 再評価ごとの PNG 再デコードを避ける）。
    @State private var thumbnailCache = ThumbnailCache()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if !model.accessibilityTrusted {
                accessibilityBanner
                Divider()
            }

            if isHistorySource {
                searchBar
                Divider()
            }

            if model.rows.isEmpty {
                Spacer()
                Text(emptyText)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                rows
                Spacer(minLength: 0)
                Divider()
                preview
                Divider()
                footer
            }
        }
        .frame(width: PaletteMetrics.width,
               height: PaletteMetrics.height(bannerShown: !model.accessibilityTrusted))
        .clipped()   // 万一コンテンツが固定高を超えてもパネル外へ描画しない保護
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if let range = model.displayedRange {
                Text("\(range.lowerBound)–\(range.upperBound)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text(sourceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// ヘッダ左のタイトル（ソース別）。
    private var headerTitle: String {
        switch model.source {
        case .history: return "Tameo — History"
        case .snippetFolders: return "Tameo — Snippets"
        case .snippetItems(let folder): return folder.title.isEmpty ? "Snippets" : folder.title
        }
    }

    /// ヘッダ右の ⇥ ヒント（切替先を示す）。
    private var sourceHint: String {
        switch model.source {
        case .history: return "⇥ Snippets"
        case .snippetFolders, .snippetItems: return "⇥ History"
        }
    }

    /// 空表示の文言（ソース別）。履歴は検索/フィルタで0件になった場合に区別する。
    private var emptyText: String {
        switch model.source {
        case .history: return model.allRows.isEmpty ? "No history yet" : "No matches"
        case .snippetFolders: return "No snippets yet"
        case .snippetItems: return "This folder is empty"
        }
    }

    /// フッターのキー凡例（ソース別。→＝入る／←＝出る を文脈で出し分け）。
    private var legend: String {
        switch model.source {
        case .history: return "type to search · 1-0 paste · ⌘P pin · ⌥# plain · esc"
        case .snippetFolders: return "→ open · 1-0 open · ⇥ History · ↑↓ move · esc"
        case .snippetItems: return "← back · 1-0 paste · ↑↓ move · esc"
        }
    }

    // MARK: - Search / Type filter（履歴ソースのみ）

    private var isHistorySource: Bool {
        if case .history = model.source { return true }
        return false
    }

    /// 検索バー（表示専用）。実フォーカスを持つ TextField は置かず、`model.query` を表示するだけ。
    /// 入力は HistoryPanelController のキーモニタが拾う（フォーカス争い・resignKey 自動クローズを避ける）。
    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.query.isEmpty {
                    Text(model.searchActive ? "Search (numbers ok)…" : "Type to search…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(model.query)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if !model.query.isEmpty || !model.typeFilter.isEmpty {
                    Text("esc clears")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            typeChips
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private struct TypeChip: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let kinds: Set<ClipKind>
    }

    private static let typeChips: [TypeChip] = [
        .init(label: "Text", symbol: "textformat", kinds: [.text]),
        .init(label: "Rich", symbol: "doc.richtext", kinds: [.rtf, .rtfd, .pdf]),
        .init(label: "Image", symbol: "photo", kinds: [.png, .tiff]),
        .init(label: "File", symbol: "doc", kinds: [.filename]),
        .init(label: "URL", symbol: "link", kinds: [.url]),
        .init(label: "Color", symbol: "paintpalette", kinds: [.color]),
    ]

    private var typeChips: some View {
        HStack(spacing: 5) {
            ForEach(Self.typeChips) { chip in
                let selected = !chip.kinds.isDisjoint(with: model.typeFilter)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        if selected { model.typeFilter.subtract(chip.kinds) }
                        else { model.typeFilter.formUnion(chip.kinds) }
                        model.reset()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: chip.symbol)
                        Text(chip.label)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Rows（固定高1ページ・スクロールなし）

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.pageItems.enumerated()), id: \.element.id) { index, row in
                rowView(index: index, row: row)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        // ソース／ページ切替を軽くクロスフェード。実発火はミューテーション側の withAnimation が駆動する。
        .id("\(model.source.key)-\(model.pageIndex)")
        .transition(.opacity)
    }

    /// 行内容の固定高（全種別で揃え、10 行が固定ページ・440pt に必ず収まることを構造的に保証）。
    private static let rowContentHeight: CGFloat = 20
    /// 種別アイコンの固定枠（≤ rowContentHeight で行高を崩さない）。
    private static let leadingSize: CGFloat = 18

    private func rowView(index: Int, row: PaletteRow) -> some View {
        let isSelected = (model.clampedRow == index)
        let badge = index == 9 ? "0" : "\(index + 1)"   // 0 = 10行目
        return Button {
            model.rowInPage = index
            onSelect(row)
        } label: {
            HStack(spacing: 8) {
                Text(badge)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, alignment: .trailing)
                // 履歴テキストだけ先頭アイコンなし＝M2 と同一外観。それ以外は固定枠のアイコンを差し込む。
                if showsLeading(row) {
                    leadingSlot(for: row, isSelected: isSelected)
                        .frame(width: Self.leadingSize, height: Self.leadingSize)
                        .clipped()
                }
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .history(let item) = row, item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .frame(height: Self.rowContentHeight)
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    /// 先頭アイコンを出すか（履歴テキストだけは出さない＝M2 と同一外観）。
    private func showsLeading(_ row: PaletteRow) -> Bool {
        if case .clip(.text) = row.leadingKind { return false }
        return true
    }

    /// 行種別ごとの先頭アイコン（固定枠）。
    @ViewBuilder
    private func leadingSlot(for row: PaletteRow, isSelected: Bool) -> some View {
        switch row {
        case .folder:
            Image(systemName: "folder")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        case .snippet:
            Image(systemName: "text.quote")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        case .history(let item):
            historyLeading(for: item, isSelected: isSelected)
        }
    }

    /// 履歴項目の種別アイコン（filename はファイルアイコン、画像はサムネ等）。`.text` は呼ばれない。
    @ViewBuilder
    private func historyLeading(for item: ClipboardItem, isSelected: Bool) -> some View {
        switch item.kind {
        case .filename:
            if let data = item.thumbnailPNG, let img = cachedImage(for: item, data: data) {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        case .png, .tiff:
            if let data = item.thumbnailPNG, let img = cachedImage(for: item, data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        case .pdf:
            Image(systemName: "doc.richtext")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        case .color:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(hexString: item.colorHex) ?? .gray))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
        case .url:
            Image(systemName: "link")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        case .rtf, .rtfd:
            Image(systemName: "textformat")
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        case .text:
            EmptyView()
        }
    }

    /// 永続ID単位でサムネ NSImage を取得（キャッシュ経由。フル原寸は読まない）。
    private func cachedImage(for item: ClipboardItem, data: Data) -> NSImage? {
        thumbnailCache.image(forKey: "\(item.persistentModelID)", data: data)
    }

    // MARK: - Preview（選択中の行の内容を貼る前に表示）

    /// 選択中の行の内容（履歴/スニペットは本文、フォルダは件数）を固定高で表示。
    /// 選択は `model.selectedRow`＝`pageIndex`/`rowInPage` から導出されるので、
    /// ↑↓・数字・ページ送りで移動すると自動で更新される。
    private var preview: some View {
        Text(previewText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(height: 52)
            .background(Color.secondary.opacity(0.06))
    }

    /// プレビュー本文。履歴/スニペットは内容、フォルダは有効スニペット数。
    private var previewText: String {
        guard let row = model.selectedRow else { return "" }
        switch row {
        case .history(let item):
            return item.content
        case .snippet(let snippet):
            return snippet.content
        case .folder(let folder):
            let n = folder.enabledSnippets.count
            return "📁 \(folder.title) · \(n) snippet\(n == 1 ? "" : "s")"
        }
    }

    // MARK: - Footer（ドット rail ＋ 位置 ＋ キー凡例）

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                // ドット rail は安全のため最大 10 個に抑える（パレットは 10 ページ上限だが将来の変更にも耐える）。
                ForEach(Array(0..<min(model.pageCount, 10)), id: \.self) { i in
                    Circle()
                        .fill(i == model.pageIndex ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(model.pageIndex + 1)/\(model.pageCount) · \(model.rows.count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(legend)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Accessibility banner

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.caption).bold()
                Text("Allow Tameo in System Settings ▸ Privacy & Security ▸ Accessibility.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open") { onRequestAccessibility() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}
