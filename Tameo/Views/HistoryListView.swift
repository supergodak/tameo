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
                .padding(8)
        } else {
            ForEach(items) { item in
                Button {
                    // 再コピー→（次tick）再ingest になるが、先に markUsed で当該項目を最新化しておくと
                    // ingest 側の「最新と同一内容なら重複を作らず lastUsedAt 更新」に当たり重複が出ない。
                    // この重複抑制は markUsed→ingest の順序と content 一致に依存する。
                    paste.copyToClipboard(item.content)
                    store.markUsed(item)
                } label: {
                    Text(item.content)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
    }
}
