import AppKit
import SwiftUI
import SwiftData
import Observation

/// 履歴パレットの一時的なUI状態。パネル表示中だけ生きる軽量な状態で、SwiftDataモデルではない。
/// `visibleItems` は `show()` 時にコントローラがスナップショット投入する“唯一の真実”。
/// 表示中は並びを凍結する（一覧がカーソル下で動かないため、index 基準の選択が安全になる）。
@MainActor
@Observable
final class PaletteModel {
    /// ハイライト中の行（`visibleItems` のインデックス）。
    var selectedIndex: Int = 0
    /// パレットに表示しているスナップショット（`show()` 時に確定。表示中は不変）。
    var visibleItems: [ClipboardItem] = []
    /// アクセシビリティ権限の有無（バナー表示の判定。`show()` 時に再評価）。
    var accessibilityTrusted: Bool = true
    /// オープンの世代。開くたびに +1 して、選択位置までスクロールし直すトリガにする。
    var sessionRevision: Int = 0

    /// `selectedIndex` を有効範囲にクランプして返す（空なら nil）。
    var clampedSelection: Int? {
        guard !visibleItems.isEmpty else { return nil }
        return min(max(selectedIndex, 0), visibleItems.count - 1)
    }

    /// 選択を delta だけ移動（端でクランプ。循環しない）。
    func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let base = clampedSelection ?? 0
        selectedIndex = min(max(base + delta, 0), visibleItems.count - 1)
    }
}

/// ホットキーで開くフローティング履歴パレット（NSPanel）の生成・表示・キー操作・選択処理を司る。
/// MenuBarExtra(.window) はホットキーから直接開けないため、貼り付け面は専用パネルで完全自前制御する。
@MainActor
final class HistoryPanelController {
    private let modelContainer: ModelContainer
    private let store: HistoryStore
    private let paste: PasteService
    private let model = PaletteModel()
    private var panel: NSPanel?
    /// パネルがキーの間だけ有効なキーイベント監視トークン。
    private var keyMonitor: Any?
    /// パネルが key を失ったら自動で閉じるための通知監視トークン。
    private var resignObserver: Any?
    /// ホットキー発火時点の前面アプリ（＝貼り付け対象）。
    private var targetApp: NSRunningApplication?

    init(modelContainer: ModelContainer, store: HistoryStore, paste: PasteService) {
        self.modelContainer = modelContainer
        self.store = store
        self.paste = paste
    }

    /// 表示中なら閉じ、非表示なら開く（ホットキー用）。
    /// resignKey で必ず自動 hide するため「表示中＝key」が保たれ、isVisible 判定で齟齬は出ない。
    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // 自分を前面化する前に、貼り付け対象を捕捉しておく。
        targetApp = NSWorkspace.shared.frontmostApplication
        // 一覧スナップショットと選択・権限状態を“キーモニタ装着前”に確定させる（遅延同期レースを排除）。
        model.visibleItems = fetchTopItems()
        model.selectedIndex = 0
        model.accessibilityTrusted = AccessibilityAuthorization.isTrusted
        model.sessionRevision &+= 1

        let panel = ensurePanel()
        if !panel.isVisible {
            positionTopCenter(panel)
        }
        installKeyMonitor()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Snapshot

    /// 現在の履歴上位（最終使用日時の新しい順）をスナップショットとして取得。
    /// ビュー側の旧 @Query と同じ並び。表示中はこの配列を凍結して使う。
    private func fetchTopItems() -> [ClipboardItem] {
        var d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        d.fetchLimit = 50
        return (try? modelContainer.mainContext.fetch(d)) ?? []
    }

    // MARK: - Key handling

    /// パネルがキーの間だけキーイベントを横取りする。フォーカス依存の `.onKeyPress` より堅牢。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ローカルモニタはメインスレッドで同期配送されるため MainActor として扱える。
            // NSEvent は非 Sendable なので、境界をまたぐのは Bool のみに留める（event は外側で返す）。
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.isKeyWindow else { return false }
                return self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 戻り値 true = 消費（システムへ流さない）。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            hide()
            return true
        case 125: // ↓
            model.moveSelection(by: 1)
            return true
        case 126: // ↑
            model.moveSelection(by: -1)
            return true
        case 36, 76: // return / keypad enter
            commitSelected()
            return true
        default:
            break
        }

        // 数字キー 1–9：その行を直接選択して確定（修飾キー併用時は無視＝⌘1 等を奪わない）。
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty,
           let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let digit = Int(chars), (1...9).contains(digit) {
            let idx = digit - 1
            if idx < model.visibleItems.count {
                model.selectedIndex = idx
                commitSelected()
            }
            return true
        }
        return false
    }

    // MARK: - Private

    private func commitSelected() {
        guard let idx = model.clampedSelection, model.visibleItems.indices.contains(idx) else { return }
        commit(model.visibleItems[idx])
    }

    /// 選択確定：パネルを閉じ、最終使用日時を更新（先頭へ）し、対象アプリへ貼り付け。
    private func commit(_ item: ClipboardItem) {
        hide()
        store.markUsed(item)
        paste.paste(item.content, to: targetApp)
    }

    /// バナーの「開く」：権限プロンプト → 未許可なら設定画面へ誘導。
    private func requestAccessibility() {
        if !AccessibilityAuthorization.requestPrompt() {
            AccessibilityAuthorization.openSettingsPane()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        // .closable は付けない：Cmd-W などの performClose が hide() を迂回してモニタを取り残すため。
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false       // 自動 hide は resignKey 監視で行う（アプリ非活性に限らず key 喪失で閉じる）
        p.becomesKeyOnlyIfNeeded = false   // パネルを確実に key にしてキー操作を受ける土台
        p.animationBehavior = .utilityWindow

        let root = HistoryPaletteView(
            onSelect: { [weak self] item in self?.commit(item) },
            onRequestAccessibility: { [weak self] in self?.requestAccessibility() }
        )
        .environment(model)

        p.contentView = NSHostingView(rootView: root)

        // key を失ったら（他ウィンドウ/他アプリへフォーカス移動）パレットを閉じる＝Spotlight 流の挙動。
        // これで「表示中だが非 key」の宙ぶらりん状態が無くなり、toggle() の反転も起きない。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        panel = p
        return p
    }

    private func positionTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.maxY - size.height - 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
