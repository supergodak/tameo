import SwiftUI
import SwiftData
import AppKit

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

            if model.rows.isEmpty {
                Spacer()
                Text(emptyText)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                rows
                Spacer(minLength: 0)
                Divider()
                footer
            }
        }
        .frame(width: 360, height: 440)
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

    /// 空表示の文言（ソース別）。
    private var emptyText: String {
        switch model.source {
        case .history: return "No history yet"
        case .snippetFolders: return "No snippets yet"
        case .snippetItems: return "This folder is empty"
        }
    }

    /// フッターのキー凡例（ソース別。→＝入る／←＝出る を文脈で出し分け）。
    private var legend: String {
        switch model.source {
        case .history: return "⇥ Snippets · ←/→ page · 1-0 paste · ↑↓ move · esc"
        case .snippetFolders: return "→ open · 1-0 open · ⇥ History · ↑↓ move · esc"
        case .snippetItems: return "← back · 1-0 paste · ↑↓ move · esc"
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

    // MARK: - Footer（ドット rail ＋ 位置 ＋ キー凡例）

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(Array(0..<model.pageCount), id: \.self) { i in
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
