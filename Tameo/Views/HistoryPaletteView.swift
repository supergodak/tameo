import SwiftUI
import SwiftData
import AppKit

/// パレットの寸法。ビュー(`HistoryPaletteView`)とパネル(`HistoryPanelController`)で同じ式を共有し、
/// 両者の高さがズレて隙間/見切れが出ないようにする。
enum PaletteMetrics {
    static let width: CGFloat = 360
    // 案B（余白・上質）: 1ページ7件（PaletteModel.pageSize）を、行間すき間つき2段組でゆったり並べる。
    // ヘッダ36＋検索/種別78＋7行(50×7+すき間5×6=380)＋プレビュー54＋フッタ44＋区切り線 ≒ 600。
    // 検索バーは履歴ソースでのみ描画され、スニペット時はその分が下部スペースに回るだけで破綻しない。
    static let baseHeight: CGFloat = 600
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
        case .history: return "Tameo"
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
        case .history: return "type to search · 1-0 paste · ⌘P pin · ⌘⌫ delete · ⌥# plain · esc"
        case .snippetFolders: return "→ open · 1-0 open · ⇥ History · ↑↓ move · esc"
        case .snippetItems: return "← back · 1-0 paste · ↑↓ move · esc"
        }
    }

    // MARK: - Search / Type filter（履歴ソースのみ）

    private var isHistorySource: Bool {
        if case .history = model.source { return true }
        return false
    }

    /// 検索バー。実フォーカスを持つ `NSSearchField` を first responder にして IME/日本語変換を効かせる。
    /// ナビ/確定系キーだけ HistoryPanelController のキーモニタが横取りし、文字・変換はフィールドが処理する。
    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                SearchFieldView(model: model)
                    .frame(height: 22)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            typeChips
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        HStack(spacing: 4) {
            ForEach(Self.typeChips) { chip in
                let selected = !chip.kinds.isDisjoint(with: model.typeFilter)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        if selected { model.typeFilter.subtract(chip.kinds) }
                        else { model.typeFilter.formUnion(chip.kinds) }
                        model.reset()
                    }
                    model.focusRequestID += 1   // クリックで奪われたフォーカスを検索フィールドへ戻す
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: chip.symbol)
                        Text(chip.label)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selected ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 実フィールド（NSSearchField）で IME を効かせる

    /// IME（日本語変換・英数/かな切替・候補選択）を成立させるため、実フォーカスを持つ NSSearchField を置く。
    /// テキストはこのフィールドが処理し、`model.query` を駆動する。ナビ/確定系キーはキーモニタ側が横取りする。
    private struct SearchFieldView: NSViewRepresentable {
        let model: PaletteModel

        func makeCoordinator() -> Coordinator { Coordinator(model: model) }

        func makeNSView(context: Context) -> NSSearchField {
            let field = NSSearchField()
            field.placeholderString = "Type to search…"
            field.focusRingType = .none
            // 案B: 自前の淡色角丸コンテナに溶け込ませるため、フィールド自身の縁/背景は描かせない。
            // さらに内蔵の虫眼鏡ボタンを消す（自前の magnifyingglass を左に置くため。残すと文字に重なる）。
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            if let cell = field.cell as? NSSearchFieldCell {
                cell.isBezeled = false
                cell.searchButtonCell = nil
            }
            field.sendsWholeSearchString = false
            field.delegate = context.coordinator
            field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            // 生成直後にフォーカス（ウィンドウ装着後に確実化するため次ループで）。
            DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(field) }
            return field
        }

        func updateNSView(_ field: NSSearchField, context: Context) {
            if field.stringValue != model.query { field.stringValue = model.query }
            // フォーカス要求が更新されたら first responder に戻す（表示時・チップ操作後）。
            if context.coordinator.lastFocusID != model.focusRequestID {
                context.coordinator.lastFocusID = model.focusRequestID
                DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(field) }
            }
        }

        final class Coordinator: NSObject, NSSearchFieldDelegate {
            let model: PaletteModel
            var lastFocusID = 0
            init(model: PaletteModel) { self.model = model }

            func controlTextDidChange(_ note: Notification) {
                guard let field = note.object as? NSSearchField else { return }
                let value = field.stringValue
                withAnimation(.easeOut(duration: 0.12)) {
                    model.query = value
                    model.reset()
                }
            }
        }
    }

    // MARK: - Rows（固定高1ページ・スクロールなし）

    private var rows: some View {
        VStack(spacing: 5) {   // 案B: 行間にすき間を入れて選択ピルを「浮かせる」
            ForEach(Array(model.pageItems.enumerated()), id: \.element.id) { index, row in
                rowView(index: index, row: row)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        // ソース／ページ切替を軽くクロスフェード。実発火はミューテーション側の withAnimation が駆動する。
        .id("\(model.source.key)-\(model.pageIndex)")
        .transition(.opacity)
    }

    /// 行内容の固定高（案B: 2段組＝本文＋種別·時刻。全種別で揃え、10 行が固定ページに収まることを保証）。
    private static let rowContentHeight: CGFloat = 34
    /// 種別アイコンの固定枠（≤ rowContentHeight で行高を崩さない）。
    private static let leadingSize: CGFloat = 22

    /// 相対時刻の整形（"2分前" / "2 min ago" 等・システムロケール依存）。
    private static let relativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func rowView(index: Int, row: PaletteRow) -> some View {
        let isSelected = (model.clampedRow == index)
        let badge = index == 9 ? "0" : "\(index + 1)"   // 0 = 10行目
        // 案B: 選択は「淡い青みのピル」。ベタ塗りをやめ、番号と本文の色で示す（アイコンも白ではなくアクセント）。
        let leadTint: Color = isSelected ? Color.accentColor : Color.secondary
        return Button {
            model.rowInPage = index
            onSelect(row)
        } label: {
            HStack(spacing: 10) {
                Text(badge)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(leadTint)
                    .frame(width: 16, alignment: .trailing)
                // 履歴テキストだけ先頭アイコンなし＝M2 と同一外観。それ以外は固定枠のアイコンを差し込む。
                if showsLeading(row) {
                    leadingSlot(for: row, isSelected: isSelected)
                        .frame(width: Self.leadingSize, height: Self.leadingSize)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    if let sub = secondaryText(for: row) {
                        Text(sub)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .history(let item) = row, item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(leadTint)
                }
            }
            .frame(height: Self.rowContentHeight)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    /// 行 2 段目の副次テキスト（案B）。履歴＝「種別 · 相対時刻」、フォルダ＝スニペット数、スニペット＝なし。
    private func secondaryText(for row: PaletteRow) -> String? {
        switch row {
        case .history(let item):
            let when = Self.relativeTime.localizedString(for: item.lastUsedAt, relativeTo: Date())
            return "\(kindLabel(item.kind)) · \(when)"
        case .folder(let folder):
            let n = folder.enabledSnippets.count
            return "\(n) snippet\(n == 1 ? "" : "s")"
        case .snippet:
            return nil
        }
    }

    /// 種別の短ラベル（2 段目・種別チップの語彙に合わせる）。
    private func kindLabel(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "Text"
        case .rtf, .rtfd: return "Rich Text"
        case .pdf: return "PDF"
        case .png, .tiff: return "Image"
        case .filename: return "File"
        case .url: return "Link"
        case .color: return "Color"
        }
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
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        case .snippet:
            Image(systemName: "text.quote")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        case .png, .tiff:
            if let data = item.thumbnailPNG, let img = cachedImage(for: item, data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        case .pdf:
            Image(systemName: "doc.text.image")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        case .color:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(hexString: item.colorHex) ?? .gray))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
        case .url:
            Image(systemName: "link")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        case .rtf, .rtfd:
            // 種別チップの Rich と同じ記号に揃える。以前は "textformat"(Aa) だったが、
            // チップ側では Aa が Text を意味するため「行の Aa ＝リッチ」と読みが衝突していた。
            Image(systemName: "doc.richtext")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
        VStack(alignment: .leading, spacing: 2) {
            if selectedHasOCRText {
                Label("⌥⏎ to paste as text", systemImage: "text.viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(selectedHasOCRText ? 2 : 3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 54)
        .background(Color.secondary.opacity(0.045))
    }

    /// 選択中の履歴項目が OCR テキストを持つか（⌥⏎ ヒント表示の判定）。
    private var selectedHasOCRText: Bool {
        if case .history(let item)? = model.selectedRow { return !item.ocrText.isEmpty }
        return false
    }

    /// プレビュー本文。履歴/スニペットは内容、フォルダは有効スニペット数。
    private var previewText: String {
        guard let row = model.selectedRow else { return "" }
        switch row {
        case .history(let item):
            // 画像はOCRテキストがあればそれを表示（⌥ でテキストとして貼れることの示唆）。
            if item.kind.isImage, !item.ocrText.isEmpty { return item.ocrText }
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
