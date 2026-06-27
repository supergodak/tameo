import SwiftUI
import SwiftData
import AppKit

/// メニューバーから開くポップオーバーの中身。
/// macOS 標準メニュー風に縦並び：ヘッダ → 履歴一覧 → アクション行（フル幅・ホバーで淡くハイライト）。
struct MenuBarContentView: View {
    @Environment(HistoryStore.self) private var store

    /// 履歴パレットを開く（ホットキー以外の導線。未設定なら非表示）。
    var onOpenPalette: (() -> Void)? = nil
    /// 更新チェック（Sparkle）。未設定なら非表示。
    var onCheckForUpdates: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダ（アプリ名＋バージョン）
            HStack(spacing: 6) {
                Text("Tameo")
                    .font(.headline)
                Spacer()
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // 履歴一覧（空のときも潰れないよう最小高を確保）
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HistoryListView()
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 76, maxHeight: 320)

            Divider()

            // アクション（縦並びメニュー）
            VStack(alignment: .leading, spacing: 1) {
                if let onOpenPalette {
                    MenuActionRow(title: "Open History", shortcut: "⌘⇧V") { onOpenPalette() }
                }
                SettingsMenuRow(title: "Settings…", shortcut: "⌘,")

                Divider().padding(.horizontal, 8).padding(.vertical, 3)

                MenuActionRow(title: "Clear History") { confirmClearHistory() }
                if let onCheckForUpdates {
                    MenuActionRow(title: "Check for Updates…") { onCheckForUpdates() }
                }
                MenuActionRow(title: "About Tameo") { showAbout() }

                Divider().padding(.horizontal, 8).padding(.vertical, 3)

                MenuActionRow(title: "Quit Tameo", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .frame(width: 300)
    }

    /// 履歴全消去の確認。MenuBarExtra(.window) では SwiftUI の confirmationDialog が
    /// メニュー窓の消失で表示されないため、メニュー窓に依存しない NSAlert（モーダル）で確認する。
    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This removes all saved clipboard items. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")             // 既定（Enter / Esc で取消）
        let clearButton = alert.addButton(withTitle: "Clear")
        clearButton.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            store.clearAll()
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

// MARK: - Menu rows（標準メニュー風の縦並び行）

/// 行ラベル（左にタイトル・右にショートカット・ホバーで淡いハイライト）。全行で共通。
@ViewBuilder
private func menuRowLabel(title: String, shortcut: String?, hovering: Bool) -> some View {
    HStack {
        Text(title)
        Spacer(minLength: 12)
        if let shortcut {
            Text(shortcut).foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(hovering ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
}

/// 通常アクション行（ボタン）。
private struct MenuActionRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            menuRowLabel(title: title, shortcut: shortcut, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 設定を開く行（SettingsLink ベース＝LSUIElement でも確実に開く。前面化は simultaneousGesture で補う）。
private struct SettingsMenuRow: View {
    let title: String
    var shortcut: String? = nil
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            menuRowLabel(title: title, shortcut: shortcut, hovering: hovering)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
        .onHover { hovering = $0 }
    }
}
