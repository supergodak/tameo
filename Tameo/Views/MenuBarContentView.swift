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
            HStack(spacing: 6) {
                Text("Tameo")
                    .font(.headline)
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Button("About") { showAbout() }
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
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

    /// "v<MARKETING_VERSION> (<CURRENT_PROJECT_VERSION>)"。ビルド番号は git コミット数で自動採番。
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    /// 標準 About パネルを前面に表示（バージョン・著作権・アイコンを Info.plist から自動表示）。
    private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
