import SwiftUI
import SwiftData

/// メニューバーから開くポップオーバーの中身（骨組み）。
/// 現状は履歴の一覧表示と終了のみ。検索・選択ペースト・プレビューは後続フェーズで追加する。
struct MenuBarContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tameo")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            Divider()

            if items.isEmpty {
                Text("履歴はまだありません")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ForEach(items) { item in
                    Text(item.content)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
            }

            Divider()

            Button("Tameo を終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 320)
    }
}
