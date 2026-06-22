import SwiftUI
import SwiftData

/// Tameo のエントリポイント。メニューバー常駐（`MenuBarExtra`）+ SwiftData。
/// サービス（HistoryStore / ClipboardMonitor / PasteService / 履歴パレット / ホットキー）を一度だけ生成して配線する。
@main
struct TameoApp: App {
    let modelContainer: ModelContainer
    @State private var store: HistoryStore
    @State private var monitor: ClipboardMonitor
    @State private var paste: PasteService
    @State private var appState: AppState
    @State private var panelController: HistoryPanelController
    @State private var hotKeyCenter: HotKeyCenter

    init() {
        do {
            let container = try ModelContainer(for: ClipboardItem.self)
            let store = HistoryStore(modelContext: container.mainContext)
            let monitor = ClipboardMonitor(store: store)
            // 起動と同時に監視開始（メニューを開く前から履歴を溜める）。
            monitor.start()

            let paste = PasteService()
            let panelController = HistoryPanelController(modelContainer: container, store: store, paste: paste)
            // ホットキー登録は起動時に一度だけ（view body 内では行わない）。
            let hotKeyCenter = HotKeyCenter(onShowHistory: { panelController.toggle() })

            self.modelContainer = container
            _store = State(initialValue: store)
            _monitor = State(initialValue: monitor)
            _paste = State(initialValue: paste)
            _appState = State(initialValue: AppState())
            _panelController = State(initialValue: panelController)
            _hotKeyCenter = State(initialValue: hotKeyCenter)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("Tameo", systemImage: "doc.on.clipboard") {
            MenuBarContentView(onOpenPalette: { panelController.show() })
                .modelContainer(modelContainer)
                .environment(store)
                .environment(paste)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
