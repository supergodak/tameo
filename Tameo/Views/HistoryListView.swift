import SwiftUI
import SwiftData

/// 履歴一覧（最終使用が新しい順）。M1は単純表示＋クリックで再コピー。
/// 番号キー選択・検索・選択ペーストはM2で追加する。
struct HistoryListView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(PasteService.self) private var paste
    @Query(sort: \ClipboardItem.lastUsedAt, order: .reverse) private var items: [ClipboardItem]

    var body: some View {
        if items.isEmpty {
            Text("No history yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            ForEach(items) { item in
                Button {
                    // 種別に応じた表現で再コピー（画像/ファイル等もここで正しく載る）。
                    // 自己コピー抑止ゲートにより監視側は再取り込みをスキップするので、重複行は出ない。
                    // markUsed で当該項目を最新化（先頭へ）。
                    paste.copyToPasteboard(item)
                    store.markUsed(item)
                } label: {
                    Text(item.content)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }
}
