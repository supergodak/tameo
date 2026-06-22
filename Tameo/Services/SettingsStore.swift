import Foundation
import Observation

/// アプリのスカラ設定の単一の真実源。スニペット本体は SwiftData（`SnippetStore`）が持ち、ここには載せない。
///
/// 方針: `@Observable` で UI へ反映しつつ、各プロパティの `didSet` で `UserDefaults` へ手書き永続化する。
/// `@AppStorage` を `@Observable` のプロパティへ直付けすると反映／ビルドの不整合が起きるため避ける
/// （ストア横断の参照を 1 経路に保つ）。ホットキーは `KeyboardShortcuts` が独自に `UserDefaults` 永続化
/// するため、ここでは二重管理しない。
///
/// S1 では `maxHistory` のみ（設定の器）。General/Types/Shortcuts/ExcludeApp の各ノブは S4 で同パターンで追加する。
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    /// 記憶する履歴数（既定 200）。`HistoryStore.maxHistory` /`HistoryPanelController.maxItems` の真実源。
    /// S1 では永続化のみ。`HistoryStore` への反映配線は S4（General タブと同時）で行う。
    var maxHistory: Int {
        didSet { defaults.set(maxHistory, forKey: Keys.maxHistory) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未設定なら既定値。init 内の代入は didSet を発火しない（不要な書き戻しを避ける）。
        self.maxHistory = (defaults.object(forKey: Keys.maxHistory) as? Int) ?? 200
    }

    private enum Keys {
        static let maxHistory = "tameo.maxHistory"
    }
}
