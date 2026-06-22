import SwiftUI
import SwiftData

/// ホットキーで開くフローティング・パレットの中身。
/// 操作: ↑↓ で選択移動 / Return で確定 / 1–9 で直接確定 / Esc で閉じる / クリックでも確定。
/// データ源は PaletteModel.visibleItems（`show()` 時に確定したスナップショット）一本。
/// キーイベントの捕捉は HistoryPanelController（NSEvent ローカルモニタ）側で行い、ここは表示専任。
struct HistoryPaletteView: View {
    @Environment(PaletteModel.self) private var model

    /// 項目確定時（クリック）。
    let onSelect: (ClipboardItem) -> Void
    /// アクセシビリティ権限の要求（バナーの「開く」）。
    let onRequestAccessibility: () -> Void

    var body: some View {
        let shown = model.visibleItems
        VStack(spacing: 0) {
            header

            Divider()

            if !model.accessibilityTrusted {
                accessibilityBanner
                Divider()
            }

            if shown.isEmpty {
                Spacer()
                Text("履歴はまだありません")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                listView(shown)
            }
        }
        .frame(width: 360, height: 440)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Tameo — 履歴")
                .font(.headline)
            Spacer()
            Text("⌘⇧V")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("ペーストには権限が必要です")
                    .font(.caption).bold()
                Text("システム設定 > プライバシーとセキュリティ > アクセシビリティ で Tameo を許可してください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("開く") { onRequestAccessibility() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func listView(_ shown: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.persistentModelID) { index, item in
                        row(index: index, item: item)
                            .id(item.persistentModelID)
                    }
                }
                .padding(.vertical, 4)
            }
            // 強調もスクロールも clampedSelection 基準に統一（両者の指す行がズレない）。
            .onChange(of: model.selectedIndex) { _, _ in scrollToSelection(proxy, shown) }
            // オープン毎（sessionRevision 変化）に選択位置へスクロールし直す（0→0 でも確実に発火）。
            .onChange(of: model.sessionRevision) { _, _ in scrollToSelection(proxy, shown) }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, _ shown: [ClipboardItem]) {
        guard let idx = model.clampedSelection, shown.indices.contains(idx) else { return }
        withAnimation(.linear(duration: 0.08)) {
            proxy.scrollTo(shown[idx].persistentModelID, anchor: .center)
        }
    }

    private func row(index: Int, item: ClipboardItem) -> some View {
        let isSelected = (model.clampedSelection == index)
        return Button {
            model.selectedIndex = index
            onSelect(item)
        } label: {
            HStack(spacing: 8) {
                Text(index < 9 ? "\(index + 1)" : " ")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(item.content)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}
