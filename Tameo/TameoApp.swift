import SwiftUI
import SwiftData

/// Tameo のエントリポイント。メニューバー常駐（`MenuBarExtra`）+ SwiftData。
/// サービス（HistoryStore / ClipboardMonitor / PasteService / AppState）を一度だけ生成して注入する。
@main
struct TameoApp: App {
    let modelContainer: ModelContainer
    @State private var store: HistoryStore
    @State private var monitor: ClipboardMonitor
    @State private var paste: PasteService
    @State private var appState: AppState

    init() {
        do {
            let container = try ModelContainer(for: ClipboardItem.self)
            let store = HistoryStore(modelContext: container.mainContext)
            let monitor = ClipboardMonitor(store: store)
            // 起動と同時に監視開始（メニューを開く前から履歴を溜める）。
            // App.init はメインスレッドで動くため、ここで張ったタイマーは main runloop で発火する。
            monitor.start()

            self.modelContainer = container
            _store = State(initialValue: store)
            _monitor = State(initialValue: monitor)
            _paste = State(initialValue: PasteService())
            _appState = State(initialValue: AppState())
        } catch {
            fatalError("ModelContainer の生成に失敗: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("Tameo", systemImage: "doc.on.clipboard") {
            MenuBarContentView()
                .modelContainer(modelContainer)
                .environment(store)
                .environment(paste)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
