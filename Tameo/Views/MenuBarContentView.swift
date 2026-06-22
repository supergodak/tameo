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
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
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

    /// 設定ウィンドウ（SwiftUI `Settings` scene）を開く。
    /// LSUIElement（Dock非表示）＋ `MenuBarExtra(.window)` 環境では `SettingsLink` だけだと
    /// 背面化しがちなため、明示的にアプリを前面化してから標準セレクタで開く。
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
