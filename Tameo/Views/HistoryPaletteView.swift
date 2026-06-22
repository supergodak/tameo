import SwiftUI
import SwiftData
import AppKit

/// ホットキーで開くフローティング・パレット（Decade Pager）。
/// 1ページ=10件(decade)を固定高で表示。操作:
///   数字 1-9,0 で表示行を即確定 / ↑↓ 行移動(端でページ送り) / ←→・Tab・[ ] でページ送り /
///   ⌘1…⌘0 で decade 直接ジャンプ / Return 確定 / Esc 閉じ / クリック確定。
/// キーイベントの捕捉は HistoryPanelController（NSEvent ローカルモニタ）側。ここは表示専任。
struct HistoryPaletteView: View {
    @Environment(PaletteModel.self) private var model

    /// 項目確定時（クリック）。
    let onSelect: (ClipboardItem) -> Void
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

            if model.visibleItems.isEmpty {
                Spacer()
                Text("No history yet")
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
            Text("Tameo — History")
                .font(.headline)
            if let range = model.displayedRange {
                Text("\(range.lowerBound)–\(range.upperBound)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text("⌘⇧V")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Rows（固定高1ページ・スクロールなし）

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.pageItems.enumerated()), id: \.element.persistentModelID) { index, item in
                row(index: index, item: item)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        // ページ切替を軽くクロスフェード。実発火はミューテーション側の withAnimation が駆動する。
        .id(model.pageIndex)
        .transition(.opacity)
    }

    /// 行内容の固定高（全種別で揃え、10 行が固定ページ・440pt に必ず収まることを構造的に保証）。
    private static let rowContentHeight: CGFloat = 20
    /// 種別アイコンの固定枠（≤ rowContentHeight で行高を崩さない）。
    private static let leadingSize: CGFloat = 18

    private func row(index: Int, item: ClipboardItem) -> some View {
        let isSelected = (model.clampedRow == index)
        let badge = index == 9 ? "0" : "\(index + 1)"   // 0 = 10行目
        return Button {
            model.rowInPage = index
            onSelect(item)
        } label: {
            HStack(spacing: 8) {
                Text(badge)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, alignment: .trailing)
                // text は先頭アイコンなし＝M2 と同一外観。非テキストのみ固定枠のアイコンを差し込む。
                if item.kind != .text {
                    leadingSlot(for: item, isSelected: isSelected)
                        .frame(width: Self.leadingSize, height: Self.leadingSize)
                        .clipped()
                }
                Text(item.content)
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

    /// 種別ごとの先頭アイコン（固定枠。`.text` は呼ばれない＝M2 と同一外観を維持）。
    /// filename はファイルアイコン（取り込み時に解決済の thumbnailPNG）。画像/色等は PR-B/C で本実装。
    @ViewBuilder
    private func leadingSlot(for item: ClipboardItem, isSelected: Bool) -> some View {
        switch item.kind {
        case .filename:
            if let data = item.thumbnailPNG, let img = cachedImage(for: item, data: data) {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        case .png, .tiff, .pdf:
            if let data = item.thumbnailPNG, let img = cachedImage(for: item, data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        case .color:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray)   // PR-C で colorHex パースに置換
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
                Text("\(model.pageIndex + 1)/\(model.pageCount) · \(model.visibleItems.count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("←/→ page · 1-0 paste · ↑↓ move · ⏎ select · esc")
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
