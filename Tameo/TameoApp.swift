import SwiftUI
import SwiftData
import AppKit

/// Tameo のエントリポイント。メニューバー常駐（`MenuBarExtra`）+ SwiftData。
/// サービス（HistoryStore / ClipboardMonitor / PasteService / 履歴パレット / ホットキー）を一度だけ生成して配線する。
@main
struct TameoApp: App {
    /// UIテスト時に設定ウィンドウを開く等のフック（`--uitest-open-settings`）。通常起動では何もしない。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer
    @State private var store: HistoryStore
    @State private var monitor: ClipboardMonitor
    @State private var paste: PasteService
    @State private var appState: AppState
    @State private var panelController: HistoryPanelController
    @State private var hotKeyCenter: HotKeyCenter?
    @State private var settings: SettingsStore
    @State private var snippetStore: SnippetStore
    @State private var updater: UpdaterController?

    /// テストホストとしてアプリが起動されたか（ユニットテスト時は XCTest 環境変数、UIテスト時は起動引数で検出）。
    /// 真のとき、クリップボード監視・ホットキー登録・Sparkle 自動更新などの副作用を止める
    /// （テストのDB/挙動検証を汚さない・初回プロンプトでハングさせないため）。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || CommandLine.arguments.contains("--uitest")
    }

    /// スクリーンショット撮影用のデモモード（DEBUG 限定・`--demo-shot=…`）。
    /// テストと同様にストア・設定を隔離し、監視／移行／ホットキー／自動更新を止める。
    static var isDemoMode: Bool {
        #if DEBUG
        return DemoSeed.requestedShot != nil
        #else
        return false
        #endif
    }

    /// 副作用（監視・移行・ホットキー・Sparkle）を起こさない実行形態か。
    private static var isSideEffectFree: Bool { isRunningTests || isDemoMode }

    init() {
        do {
            // 専用ストアパスを明示指定する（重要）。設定なしの ModelContainer(for:) は全アプリ共用の
            // ~/Library/Application Support/default.store に書き、他アプリ／Appleエージェントが
            // 同じストアを開くと軽量マイグレーションで当方のデータが削除される（2026-07-08 に実発生）。
            // 詳細と旧ストアからの一度きり移行は StoreLocation を参照。
            // テスト実行時は**ストアも隔離**する（設定と同じ理由）。テストホストが実ストアを開くと、
            // 開発中のスキーマ変更が実データへ勝手に軽量マイグレーションされる
            // （2026-07-22 に実発生: テスト実行だけで実ストアの列が改名された。データは無傷だが危険）。
            let storeURL: URL
            if Self.isDemoMode {
                // デモは毎回まっさらな別ストアから（前回の seed を残さない）。実ストアには触れない。
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tameo-demo-store", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                storeURL = dir.appendingPathComponent("Tameo.store")
            } else if Self.isRunningTests {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tameo-testhost-store", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                storeURL = dir.appendingPathComponent("Tameo.store")
            } else {
                storeURL = try StoreLocation.dedicatedStoreURL()
                StoreLocation.migrateLegacyDefaultStoreIfNeeded(to: storeURL)
            }
            // 履歴に加えスニペット2モデルを同一ストアへ。既定値付きフィールドのみのため
            // 既存 ClipboardItem データはエンティティ追加だけで無傷（lightweight migration）。
            let container = try Self.makeContainer(at: storeURL)
            // スカラ設定の真実源（履歴数・ソート順・⌘V自動入力・ログイン時起動）。消費側へ注入する。
            // テスト実行時（ユニット/UI）は設定の永続化先を「使い捨ての隔離ドメイン」にする（重要）。
            // 実アプリの UserDefaults(.standard) を使うと、UIテストがトグルを操作した結果が実ユーザー設定へ
            // 焼き付く（2026-07-09: UIテストが storeText / 自動⌘V を OFF に固定し、実機でテキスト保存が
            // 止まる事故が発生）。毎起動でこのドメインをリセットし、テスト間の状態漏れも同時に防ぐ。
            let settings: SettingsStore
            if Self.isSideEffectFree {
                let suiteName = Self.isDemoMode ? "jp.co.ati-mirai.tameo.demo" : "jp.co.ati-mirai.tameo.uitest"
                let suite = UserDefaults(suiteName: suiteName) ?? .standard
                suite.removePersistentDomain(forName: suiteName)
                settings = SettingsStore(defaults: suite)
            } else {
                settings = SettingsStore()
            }
            let store = HistoryStore(modelContext: container.mainContext, settings: settings)
            // スニペットの書き込み主体（HistoryStore と同じ mainContext を共有）。パレットにも渡す。
            let snippetStore = SnippetStore(modelContext: container.mainContext)
            // 自己コピー抑止ゲートを監視とペーストで共有（貼り戻し由来の重複行を防ぐ）。
            let gate = PasteboardWriteGate()
            let monitor = ClipboardMonitor(store: store, gate: gate, settings: settings)
            let paste = PasteService(gate: gate, settings: settings)
            let panelController = HistoryPanelController(
                modelContainer: container, store: store, snippetStore: snippetStore,
                paste: paste, settings: settings)

            // テスト実行時（ユニット/UI のテストホスト）は副作用を起こさない：クリップボード監視・
            // 一度きりの補完/掃除・グローバルホットキー登録・Sparkle 自動更新を止める。これらは実行環境に
            // 依存し、テストのDB/挙動検証を汚す／初回プロンプトでハングさせるため。
            var hotKeyCenter: HotKeyCenter?
            var updater: UpdaterController?
            if !Self.isSideEffectFree {
                monitor.start()                          // 起動と同時に監視開始（履歴を溜める）
                store.encryptLegacyHistoryIfNeeded(storeURL: storeURL)  // 平文履歴の一度きり暗号化（バックアップ→移行。他の一度きり処理より先）
                store.backfillSearchIndexIfNeeded()      // 既存行の検索インデックス補完（UserDefaults ガード）
                store.dedupeExistingHistoryIfNeeded()    // 溜まった重複の一度きり掃除（UserDefaults ガード）
                hotKeyCenter = HotKeyCenter(             // ⌘⇧V=履歴 / ⌘⇧B=スニペット（起動時に一度だけ）
                    onShowHistory: { panelController.toggle() },
                    onShowSnippets: { panelController.toggleSnippets() }
                )
                updater = UpdaterController()            // Sparkle 自動更新（生成で定期チェック開始）
            }

            // UIテスト時のみ: 設定画面を通常ウィンドウとして開けるよう、環境注入済みのビューを AppDelegate に渡す
            // （メニューバー常駐アプリは SwiftUI の Settings/Window シーンを起動時に確実には出せないため、
            //  AppDelegate が NSHostingController の素のウィンドウとして提示する）。
            if Self.isRunningTests && CommandLine.arguments.contains("--uitest-open-settings") {
                AppDelegate.settingsContent = AnyView(
                    SettingsView()
                        .modelContainer(container)
                        .environment(settings)
                        .environment(snippetStore)
                )
            }

            self.modelContainer = container
            _store = State(initialValue: store)
            _monitor = State(initialValue: monitor)
            _paste = State(initialValue: paste)
            _appState = State(initialValue: AppState())
            _panelController = State(initialValue: panelController)
            _hotKeyCenter = State(initialValue: hotKeyCenter)
            _settings = State(initialValue: settings)
            _snippetStore = State(initialValue: snippetStore)
            _updater = State(initialValue: updater)

            #if DEBUG
            // デモモード: 無害なデータを投入し、指定の画面でパレットを中央に開く（撮影用）。
            // UI が立ち上がってから実行するため main へ非同期投入。OCR の非同期認識に少し猶予を置く。
            if let shot = DemoSeed.requestedShot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    DemoSeed.populate(store: store, snippets: snippetStore)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        panelController.demoShow(shot)
                    }
                }
            }
            #endif
        } catch {
            // ここへ来るのは、退避して作り直してもなお開けない場合だけ（ディスク不足・権限など）。
            // ストアが 1 つも開けないならアプリは機能しないため、原因が残るよう停止する。
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// ストアを開く。壊れていて開けない場合は、そのファイルを退避してから空のストアで開き直す。
    ///
    /// 以前はここで素通しに throw して `fatalError` に落ちていたため、ストアが一度壊れると
    /// アプリが二度と起動せず、ユーザーは `~/Library/Application Support/Tameo/` を自力で
    /// 消すまで復旧できなかった。履歴を失うのは痛いが、起動不能よりは軽い。壊れたファイルは
    /// 削除せず退避するので、後から手で救出できる。
    private static func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(url: storeURL)
        let models: [any PersistentModel.Type] = [ClipboardItem.self, SnippetFolder.self, Snippet.self]
        do {
            return try ModelContainer(for: Schema(models), configurations: config)
        } catch {
            NSLog("Tameo: ストアを開けませんでした。退避して作り直します: %@", String(describing: error))
            StoreLocation.quarantineStore(at: storeURL)
            return try ModelContainer(for: Schema(models), configurations: config)
        }
    }

    var body: some Scene {
        MenuBarExtra("Tameo", systemImage: "doc.on.clipboard") {
            MenuBarContentView(
                onOpenPalette: { panelController.show() },
                onCheckForUpdates: { updater?.checkForUpdates() }
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

/// アプリデリゲート。通常起動では実質何もしない。UIテスト時のみ、起動引数に応じて設定ウィンドウを開く
/// （メニューバー常駐アプリは主ウィンドウを持たないため、XCUITest から設定画面を検査するには自前で開く必要がある）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// UIテスト時に開く設定画面（環境注入済み）。`TameoApp.init` が --uitest-open-settings のとき設定する。
    static var settingsContent: AnyView?
    /// 提示したウィンドウの retain（デリゲート/シーンに載らない素のウィンドウなので自前で保持）。
    private var uiTestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let content = Self.settingsContent else { return }
        // メニューバー常駐（LSUIElement）でも XCUITest から検査できるよう通常アプリ化し、設定画面を
        // NSHostingController の素のウィンドウとして前面に出す（SwiftUI シーンに依存しない確実な経路）。
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Tameo Settings"
        window.setContentSize(NSSize(width: 620, height: 440))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        uiTestWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
