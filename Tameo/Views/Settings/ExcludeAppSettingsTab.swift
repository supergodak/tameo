import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 除外アプリ設定タブ。これらのアプリが前面のときにコピーした内容は履歴に残さない。
/// 保存先は `SettingsStore.excludedBundleIDs`、判定は `ClipboardMonitor`（前面アプリの bundle id 比較）。
struct ExcludeAppSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selection: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            if settings.excludedBundleIDs.isEmpty {
                Spacer()
                Text("No excluded apps.\nAdd an app to stop recording anything copied while it is frontmost.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { id in
                        Label(Self.displayName(for: id), systemImage: "app.dashed")
                            .help(id)
                            .tag(id)
                    }
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button { addApps() } label: { Image(systemName: "plus") }
                    .help("Add app…")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .help("Remove")
                    .disabled(selection == nil)
                Spacer()
                Text("Concealed (password) items are excluded separately in the Types tab.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Actions

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to exclude from clipboard history"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        var ids = settings.excludedBundleIDs
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) else { continue }
            ids.append(id)
        }
        settings.excludedBundleIDs = ids
    }

    private func removeSelected() {
        guard let selection else { return }
        settings.excludedBundleIDs.removeAll { $0 == selection }
        self.selection = nil
    }

    /// bundle id から表示名を解決（見つかればアプリ名、無ければ bundle id をそのまま）。
    private static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
