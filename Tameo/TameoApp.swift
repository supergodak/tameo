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
    @State private var settings: SettingsStore
    @State private var snippetStore: SnippetStore
    @State private var updater: UpdaterController

    init() {
        do {
            // 専用ストアパスを明示指定する（重要）。設定なしの ModelContainer(for:) は全アプリ共用の
            // ~/Library/Application Support/default.store に書き、他アプリ／Appleエージェント
            // （icloudmailagent 等）が同じストアを開くと軽量マイグレーションで当方のデータが削除される
            // （2026-07-08 に実発生：履歴・スニペット全消失）。詳細と旧ストアからの一度きり移行は StoreLocation を参照。
            let storeURL = try StoreLocation.dedicatedStoreURL()
            StoreLocation.migrateLegacyDefaultStoreIfNeeded(to: storeURL)
            // 履歴に加えスニペット2モデルを同一ストアへ。既定値付きフィールドのみのため
            // 既存 ClipboardItem データはエンティティ追加だけで無傷（lightweight migration）。
            let container = try ModelContainer(
                for: ClipboardItem.self, SnippetFolder.self, Snippet.self,
                configurations: ModelConfiguration(url: storeURL))
            // スカラ設定の真実源（履歴数・ソート順・⌘V自動入力・ログイン時起動）。消費側へ注入する。
            let settings = SettingsStore()
            let store = HistoryStore(modelContext: container.mainContext, settings: settings)
            // スニペットの書き込み主体（HistoryStore と同じ mainContext を共有）。パレットにも渡す。
            let snippetStore = SnippetStore(modelContext: container.mainContext)
            // 自己コピー抑止ゲートを監視とペーストで共有（貼り戻し由来の重複行を防ぐ）。
            let gate = PasteboardWriteGate()
            let monitor = ClipboardMonitor(store: store, gate: gate, settings: settings)
            // 起動と同時に監視開始（メニューを開く前から履歴を溜める）。
            monitor.start()
            // 既存（M5前）の行に検索インデックスを一度だけ補完（UserDefaults でガード）。
            store.backfillSearchIndexIfNeeded()
            // 全体重複排除の導入前に溜まった重複行を一度だけ掃除（UserDefaults でガード）。
            store.dedupeExistingHistoryIfNeeded()

            let paste = PasteService(gate: gate, settings: settings)
            let panelController = HistoryPanelController(
                modelContainer: container, store: store, snippetStore: snippetStore,
                paste: paste, settings: settings)
            // ホットキー登録は起動時に一度だけ（view body 内では行わない）。⌘⇧V=履歴 / ⌘⇧B=スニペット。
            let hotKeyCenter = HotKeyCenter(
                onShowHistory: { panelController.toggle() },
                onShowSnippets: { panelController.toggleSnippets() }
            )

            self.modelContainer = container
            _store = State(initialValue: store)
            _monitor = State(initialValue: monitor)
            _paste = State(initialValue: paste)
            _appState = State(initialValue: AppState())
            _panelController = State(initialValue: panelController)
            _hotKeyCenter = State(initialValue: hotKeyCenter)
            _settings = State(initialValue: settings)
            _snippetStore = State(initialValue: snippetStore)
            // Sparkle 自動更新。生成と同時にバックグラウンドの定期チェックが始まる。
            _updater = State(initialValue: UpdaterController())
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("Tameo", systemImage: "doc.on.clipboard") {
            MenuBarContentView(
                onOpenPalette: { panelController.show() },
                onCheckForUpdates: { updater.checkForUpdates() }
            )
                .modelContainer(modelContainer)
                .environment(store)
                .environment(paste)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .environment(settings)
                .environment(snippetStore)
        }
    }
}
