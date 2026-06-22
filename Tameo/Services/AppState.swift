import Foundation
import SwiftData
import Observation

/// 揮発的なUI状態のみを持つ。履歴データ本体は持たない（それは @Query / SwiftData 側）。
@MainActor
@Observable
final class AppState {
    var searchText: String = ""
    var selectedItemID: PersistentIdentifier?
    var isPopoverPresented: Bool = false

    /// M2で KeyboardShortcuts の登録を実装する。M1では配線形だけ確定させる no-op。
    func registerHotkeys() {
        // M2: KeyboardShortcuts.onKeyDown(for: .showMain) { ... }
    }
}
