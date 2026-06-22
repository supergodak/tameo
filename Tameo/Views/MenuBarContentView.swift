import SwiftUI
import SwiftData

/// メニューバーから開くポップオーバーの中身。
/// 履歴一覧（`HistoryListView`）＋「履歴をクリア」＋終了。
struct MenuBarContentView: View {
    @Environment(HistoryStore.self) private var store
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tameo")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HistoryListView()
                }
            }
            .frame(maxHeight: 360)

            Divider()

            HStack {
                Button("履歴をクリア") { confirmClear = true }
                Spacer()
                Button("Tameo を終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 320)
        .confirmationDialog("履歴をすべて消去しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("消去", role: .destructive) {
                store.clearAll()
            }
            Button("キャンセル", role: .cancel) { }
        }
    }
}
