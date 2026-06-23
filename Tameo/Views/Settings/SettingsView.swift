import SwiftUI

/// 設定ウィンドウのルート（SwiftUI `Settings` scene の中身）。
/// Clipy の設定パネル群に対応するタブを並べる。S1 では Snippets タブのみ実装し、
/// General / Types / Shortcuts / ExcludeApp は S4 で追加する。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TypesSettingsTab()
                .tabItem { Label("Types", systemImage: "square.on.square") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            SnippetsSettingsTab()
                .tabItem { Label("Snippets", systemImage: "text.quote") }
        }
        .frame(width: 620, height: 440)
    }
}
