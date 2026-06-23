import SwiftUI
import SwiftData

/// メニューバーから開くポップオーバーの中身。
/// 履歴一覧（`HistoryListView`）＋「履歴をクリア」＋終了。
struct MenuBarContentView: View {
    @Environment(HistoryStore.self) private var store
    @State private var confirmClear = false

    /// 履歴パレットを開く（ホットキー以外の導線。未設定なら非表示）。
    var onOpenPalette: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tameo")
                    .font(.headline)
                Spacer()
                if let onOpenPalette {
                    Button("Open History  ⌘⇧V") { onOpenPalette() }
                        .font(.caption)
                }
            }
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
                Button("Clear History") { confirmClear = true }
                Spacer()
                // SettingsLink は SwiftUI の Settings scene を開く公式 API（⌘, の組み込み経路と同じ）。
                // sendAction(showSettingsWindow:) は MenuBarExtra ポップオーバーのレスポンダチェーンに
                // 届かず不発になるため使わない。前面化は simultaneousGesture で明示的に補い、
                // ポップオーバー表示中の ⌘, も明示ショートカットで担保する。
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate()
                })
                Button("Quit Tameo") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 320)
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}
