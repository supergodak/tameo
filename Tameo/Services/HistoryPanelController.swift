import AppKit
import SwiftUI
import SwiftData
import Observation

/// 履歴パレットの一時的なUI状態（Decade Pager）。
/// 一覧を 10 件＝1ページ（decade）に区切り、`pageIndex` と「ページ内の選択行 `rowInPage`(0..9)」で
/// 選択を表す。グローバル添字は確定時にだけ導出する（ページ境界の桁ズレを避けるための単一基準）。
/// `rows` は `show()` 時のスナップショット（履歴は設定の最大件数）で、表示中は不変。
@MainActor
@Observable
final class PaletteModel {
    static let pageSize = 10

    /// 現在のページ（decade）。0 始まり。
    var pageIndex: Int = 0
    /// 現ページ内で選択中の行（0..9）。
    var rowInPage: Int = 0
    /// 全件スナップショット（`show()` 時に固める不変の元データ）。検索/フィルタはこれを絞り込む。
    var allRows: [PaletteRow] = []
    /// 検索クエリ（履歴ソースでのみ有効）。
    var query: String = ""
    /// 種別フィルタ（空＝全種別）。
    var typeFilter: Set<ClipKind> = []
    /// `/` で入る検索モード（クエリ空でも数字をクエリに入れるためのフラグ）。
    var searchActive: Bool = false
    /// 検索フィールドへ first responder を移すよう要求するカウンタ（表示時・チップ操作後に増やす）。
    var focusRequestID: Int = 0
    /// アクセシビリティ権限の有無（バナー表示の判定。`show()` 時に再評価）。
    var accessibilityTrusted: Bool = true
    /// 現在の表示ソース（履歴 / スニペットフォルダ一覧 / フォルダの中身）。
    var source: PaletteSource = .history
    /// スニペット階層の復帰用スタック（フォルダに入った履歴。Esc で 1 階層戻る）。
    /// Clipy のフォルダは入れ子なしのため現状は深さ 1（非空＝フォルダの中身を表示中）。
    var snippetStack: [SnippetFolder] = []

    /// 表示行（導出）。履歴ソースでは種別フィルタ→テキスト検索の順に絞り、ピン留めを最上段へ。
    /// 履歴以外（スニペット）は `allRows` をそのまま返す（v1では検索/フィルタ対象外）。
    /// `pageItems`/番号貼付/ページャ/フッタはすべてこの `rows` から導出されるため、絞り込みに自動追従する。
    var rows: [PaletteRow] {
        guard case .history = source else { return allRows }
        var result = allRows
        if !typeFilter.isEmpty {
            result = result.filter {
                if case .history(let item) = $0 { return typeFilter.contains(item.kind) }
                return false
            }
        }
        let q = SearchNormalizer.normalize(query)
        if !q.isEmpty {
            result = result.filter {
                if case .history(let item) = $0 { return item.searchIndex.contains(q) }
                return false
            }
        }
        // ピン最上段（安定分割。別セクションにせず単一リストでページャ計算を保つ）。
        var pinned: [PaletteRow] = []
        var rest: [PaletteRow] = []
        for row in result {
            if case .history(let item) = row, item.isPinned { pinned.append(row) } else { rest.append(row) }
        }
        return pinned + rest
    }

    var pageCount: Int {
        max(1, (rows.count + Self.pageSize - 1) / Self.pageSize)
    }
    var pageStart: Int { pageIndex * Self.pageSize }

    /// 現ページに表示する 10 件（最終ページは 10 件未満になりうる）。
    var pageItems: [PaletteRow] {
        guard pageStart < rows.count else { return [] }
        return Array(rows[pageStart ..< min(pageStart + Self.pageSize, rows.count)])
    }

    /// 現ページ内の有効な選択行（空なら nil）。ハイライト判定に使う。
    var clampedRow: Int? {
        let c = pageItems.count
        guard c > 0 else { return nil }
        return min(max(rowInPage, 0), c - 1)
    }

    /// 確定対象の行（グローバル添字はここで導出）。
    var selectedRow: PaletteRow? {
        let items = pageItems
        guard let row = clampedRow, items.indices.contains(row) else { return nil }
        return items[row]
    }

    /// 表示中の項目レンジ（1始まり）。例: 11...20。
    var displayedRange: ClosedRange<Int>? {
        let items = pageItems
        guard !items.isEmpty else { return nil }
        return (pageStart + 1)...(pageStart + items.count)
    }

    /// 開くたびに先頭ページ・先頭行へ。
    func reset() {
        pageIndex = 0
        rowInPage = 0
    }

    /// ページ内で選択を移動。端では隣ページへロールオーバー（末端ではクランプ）。
    func moveRow(by delta: Int) {
        let count = pageItems.count
        guard count > 0 else { return }
        let cur = min(max(rowInPage, 0), count - 1)
        let next = cur + delta
        if next < 0 {
            if pageIndex > 0 {
                pageIndex -= 1
                rowInPage = max(0, pageItems.count - 1)   // 前ページの最終行へ
            } else {
                rowInPage = 0
            }
        } else if next >= count {
            if pageIndex < pageCount - 1 {
                pageIndex += 1
                rowInPage = 0                              // 次ページの先頭へ
            } else {
                rowInPage = count - 1
            }
        } else {
            rowInPage = next
        }
    }

    /// ページを相対移動。選択行オフセット `rowInPage` は保持し、表示・確定時に clampedRow/selectedRow 側で
    /// クランプする（短い最終ページを通過しても元のオフセットが壊れない）。
    func page(by delta: Int) {
        pageIndex = min(max(pageIndex + delta, 0), pageCount - 1)
    }

    /// 指定ページ（decade）へ直接ジャンプ（選択行オフセットは保持）。
    func goToPage(_ n: Int) {
        pageIndex = min(max(n, 0), pageCount - 1)
    }
}

/// ホットキーで開くフローティング履歴パレット（NSPanel）の生成・表示・キー操作・選択処理を司る。
/// MenuBarExtra(.window) はホットキーから直接開けないため、貼り付け面は専用パネルで完全自前制御する。
@MainActor
final class HistoryPanelController {
    /// パレットに表示する履歴の最大件数（10 ページ＝10 件×10）。ストレージ保持上限 `settings.maxHistory`
    /// （最大 1000）とは別物。⌘N の到達範囲とフッターのドット rail を 10 ページに収め、UI 破綻を防ぐ。
    private static let paletteItemCap = 100

    private let modelContainer: ModelContainer
    private let store: HistoryStore
    private let snippetStore: SnippetStore
    private let paste: PasteService
    private let settings: SettingsStore
    private let model = PaletteModel()
    private var panel: NSPanel?
    /// パネルがキーの間だけ有効なキーイベント監視トークン。
    private var keyMonitor: Any?
    /// パネルが key を失ったら自動で閉じるための通知監視トークン。
    private var resignObserver: Any?
    /// 表示中だけ有効な「パネル外クリック」監視トークン（key になれない時の閉じ保険）。
    private var outsideClickMonitor: Any?
    /// ホットキー発火時点の前面アプリ（＝貼り付け対象）。
    private var targetApp: NSRunningApplication?

    init(modelContainer: ModelContainer, store: HistoryStore, snippetStore: SnippetStore,
         paste: PasteService, settings: SettingsStore) {
        self.modelContainer = modelContainer
        self.store = store
        self.snippetStore = snippetStore
        self.paste = paste
        self.settings = settings
    }

    /// 表示中なら閉じ、非表示なら履歴を開く（⌘⇧V 用）。
    /// resignKey で必ず自動 hide するため「表示中＝key」が保たれ、isVisible 判定で齟齬は出ない。
    func toggle() {
        if let panel, panel.isVisible { hide() } else { show(source: .history) }
    }

    /// 表示中なら閉じ、非表示ならスニペット一覧を開く（⌘⇧B 用）。
    func toggleSnippets() {
        if let panel, panel.isVisible { hide() } else { show(source: .snippetFolders) }
    }

    func show(source: PaletteSource = .history) {
        // 自分を前面化する前に、貼り付け対象を捕捉しておく。
        targetApp = NSWorkspace.shared.frontmostApplication
        // スナップショットと選択・権限状態を“キーモニタ装着前”に確定させる（遅延同期レースを排除）。
        switch source {
        case .history: loadHistory()
        case .snippetFolders: loadSnippetFolders()
        case .snippetItems(let folder): loadSnippetFolders(); enterFolder(folder)
        }
        model.accessibilityTrusted = AccessibilityAuthorization.isTrusted

        let panel = ensurePanel()
        // バナー（権限未許可）の有無で縦を変える。ビュー側 `.frame` と同じ式で揃え、隙間/見切れを防ぐ。
        panel.setContentSize(NSSize(
            width: PaletteMetrics.width,
            height: PaletteMetrics.height(bannerShown: !model.accessibilityTrusted)
        ))
        positionAtMouse(panel)   // 開くたびにカーソル位置へ（Clipy流。視線/マウス移動を最小化）
        installKeyMonitor()
        installOutsideClickMonitor()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // 履歴では検索フィールドへフォーカスを移す（IME/日本語変換を効かせるため）。
        if case .history = model.source { model.focusRequestID += 1 }
        // (2) key 再取得リトライ: セキュアな自動入力ポップアップ等でキーを掴めなかった時、
        // 次のランループで一度だけ再アクティブ化＆makeKey を試みる（掴める状況なら掴む）。
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
            NSApp.activate()
            panel.makeKey()
            if case .history = self.model.source { self.model.focusRequestID += 1 }
        }
    }

    func hide() {
        removeKeyMonitor()
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Source loading（表示ソースの切替・スニペット階層）

    /// 履歴ソースへ。設定のソート順・最大件数でスナップショット。
    private func loadHistory() {
        model.source = .history
        model.snippetStack.removeAll()
        let items = fetchTopItems()
        model.allRows = items.map { PaletteRow.history($0) }
        store.recognizeMissing(in: items)   // 既存画像の未OCR分を遅延認識（検索可能化）
        clearSearchState()
        model.reset()
    }

    /// スニペットのフォルダ一覧（トップ）へ。有効なフォルダのみ、order 昇順。
    private func loadSnippetFolders() {
        model.source = .snippetFolders
        model.snippetStack.removeAll()
        model.allRows = snippetStore.enabledFolders().map { PaletteRow.folder($0) }
        clearSearchState()
        model.reset()
    }

    /// フォルダの中身（有効スニペット, order 昇順）へ入る。Esc で戻れるよう階層を push。
    private func enterFolder(_ folder: SnippetFolder) {
        model.snippetStack.append(folder)
        model.source = .snippetItems(folder)
        model.allRows = folder.enabledSnippets.map { PaletteRow.snippet($0) }
        clearSearchState()
        model.reset()
    }

    /// 検索クエリ・種別フィルタ・検索モードを初期化する（ソース切替時に呼ぶ）。
    private func clearSearchState() {
        model.query = ""
        model.typeFilter = []
        model.searchActive = false
    }

    /// ⇥：History ⇄ Snippets（ルート）を切り替える。
    private func switchSource() {
        switch model.source {
        case .history: loadSnippetFolders()
        case .snippetFolders, .snippetItems: loadHistory()
        }
    }

    /// → ：スニペットのフォルダ一覧で選択がフォルダなら中へ入る、それ以外はページ送り（次）。
    private func handleRightArrow() {
        if case .snippetFolders = model.source, case .folder(let folder)? = model.selectedRow {
            animated { enterFolder(folder) }
        } else {
            animated { model.page(by: 1) }
        }
    }

    /// ← ：フォルダの中身を見ているときは 1 階層戻る、それ以外はページ送り（前）。
    private func handleLeftArrow() {
        if case .snippetItems = model.source {
            animated { loadSnippetFolders() }
        } else {
            animated { model.page(by: -1) }
        }
    }

    // MARK: - Snapshot

    /// 現在の履歴上位を設定のソート順・最大件数でスナップショットする。
    /// 表示中はこの配列を凍結して使う（ページUIなので背は固定、画面外化しない）。
    private func fetchTopItems() -> [ClipboardItem] {
        let sort: [SortDescriptor<ClipboardItem>]
        switch settings.sortOrder {
        case .lastUsed: sort = [SortDescriptor(\.lastUsedAt, order: .reverse)]
        case .createdAt: sort = [SortDescriptor(\.createdAt, order: .reverse)]
        }
        var d = FetchDescriptor<ClipboardItem>(sortBy: sort)
        // 保持上限 maxHistory は最大 1000 まで可変だが、パレット表示は 10 ページ(100件)に抑える
        // （⌘N の到達範囲・ドット rail を破綻させない。残りはストレージに保持され将来の検索で辿れる）。
        d.fetchLimit = min(settings.maxHistory, Self.paletteItemCap)
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

    /// (1) 閉じ保険: 表示中だけ、パレット外の左/右クリックで閉じる。
    /// グローバルモニタは他アプリ/デスクトップに配送されるクリックのみ受け取る（＝パレット外クリック）。
    /// パネルがキーになれず resignKey が来ない状況でも確実に閉じられる。
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// ページ変化を伴う操作はトランザクションで包み、クロスフェード（.id+.transition）を実発火させる。
    private func animated(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.12), change)
    }

    /// 戻り値 true = 消費（システムへ流さない）。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let isHistory: Bool = { if case .history = model.source { return true }; return false }()

        // IME 変換中（マーク済みテキストあり）は一切横取りせず、すべて検索フィールドへ通す。
        // 日本語変換・候補選択・英数/かな切替・Esc取消などを IME に委ねる。
        if isHistory, let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }

        switch event.keyCode {
        case 53: // esc：検索/フィルタがあれば先にクリア、次にスニペット階層を戻る、最後に閉じる
            if isHistory, model.searchActive || !model.query.isEmpty || !model.typeFilter.isEmpty {
                animated { clearSearchState(); model.reset() }
            } else if !model.snippetStack.isEmpty {
                animated { loadSnippetFolders() }
            } else {
                hide()
            }
            return true
        case 125: animated { model.moveRow(by: 1) }; return true                  // ↓
        case 126: animated { model.moveRow(by: -1) }; return true                 // ↑
        case 33: animated { model.page(by: -1) }; return true                     // [ : ページ送り（前）
        case 30: animated { model.page(by: 1) }; return true                      // ] : ページ送り（次）
        case 123: handleLeftArrow(); return true                                  // ← : 出る or ページ送り（前）
        case 124: handleRightArrow(); return true                                 // → : 入る or ページ送り（次）
        case 48: animated { switchSource() }; return true                         // ⇥ : History ⇄ Snippets
        case 36, 76: commitSelected(asPlainText: event.modifierFlags.contains(.option)); return true  // ⏎（⌥=平文）
        default: break
        }

        // ⌘P：選択中の履歴項目のピン留めを切替（ピンは最上段へ移動）。
        if isHistory,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "p",
           case .history(let item)? = model.selectedRow {
            animated { store.setPinned(item, !item.isPinned); model.reset() }
            return true
        }

        // `/`：クエリが空のとき検索モードに入る（数字始まり検索を可能にする）。フィールドへは通さない。
        // 文字・かな・IME 等の通常入力は横取りせず、first responder の検索フィールドが処理する。
        if isHistory,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           event.characters == "/", model.query.isEmpty, !model.searchActive {
            model.searchActive = true
            return true
        }

        // 数字キー（1-9, 0）。0 は各ページの 10 行目。Shift も判定対象に含め、⇧+数字の誤爆ペーストを防ぐ。
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let digit = Int(chars), (0...9).contains(digit) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if mods == .command {
            // ⌘N: decade へ直接ジャンプ（⌘1=1ページ目 … ⌘0=10ページ目）。確定はしない。範囲外は無視（消費のみ）。
            let target = digit == 0 ? 9 : digit - 1
            if target < model.pageCount {
                animated { model.goToPage(target) }
            }
            return true
        }
        if mods == .option {
            // ⌥+数字: 平文で貼り付け（リッチ装飾を捨てる）。⇧等の誤爆を避けるため厳密一致で判定。
            let row = digit == 0 ? 9 : digit - 1
            if row < model.pageItems.count {
                model.rowInPage = row
                commitSelected(asPlainText: true)
            }
            return true
        }
        if mods.isEmpty {
            // 履歴で検索中（モード or クエリ非空）なら数字はクエリへ＝フィールドに通す。
            if isHistory, model.searchActive || !model.query.isEmpty {
                return false
            }
            // それ以外: 現ページの該当行を選択して即確定（番号クイック貼付）。
            let row = digit == 0 ? 9 : digit - 1
            if row < model.pageItems.count {
                model.rowInPage = row
                commitSelected()
            }
            return true
        }
        return false
    }

    // MARK: - Private

    private func commitSelected(asPlainText: Bool = false) {
        guard let row = model.selectedRow else { return }
        commit(row, asPlainText: asPlainText)
    }

    /// 選択確定：履歴/スニペットは貼り付けて閉じ、フォルダは中へ入る（閉じない）。
    /// `asPlainText`=true（⌥）はリッチ装飾を捨てて平文で貼る（履歴の RTF/RTFD 等向け）。
    private func commit(_ row: PaletteRow, asPlainText: Bool = false) {
        switch row {
        case .folder(let folder):
            animated { enterFolder(folder) }
        case .history(let item):
            hide()
            store.markUsed(item)
            // ⌥（平文）＋ OCRテキストあり → 画像/パスでなく認識テキストを貼る。
            // 画像ピクセル(png/tiff)・画像ファイルを指す filename の両方を対象にする。
            if asPlainText, !item.ocrText.isEmpty {
                paste.pasteText(item.ocrText, to: targetApp)
            } else {
                paste.paste(item, asPlainText: asPlainText, to: targetApp)
            }
        case .snippet(let snippet):
            hide()
            // スニペット本文は元から平文。pasteText は gate を通すので履歴を汚染しない。
            paste.pasteText(snippet.content, to: targetApp)
        }
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
            onSelect: { [weak self] row in self?.commit(row) },
            onRequestAccessibility: { [weak self] in self?.requestAccessibility() }
        )
        .environment(model)

        // .titled + .fullSizeContentView はタイトルバー相当の上部セーフエリア inset を生む。
        // ルートは固定高 440 のため、inset で縮んだ領域に中央寄せされ上下（ヘッダ／凡例）が見切れる。
        // セーフエリアを無視させ、コンテンツをパネル全面（440pt）にぴったり敷く。
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        p.contentView = hosting

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

    /// パレットの左上をマウスカーソル付近に置く（Clipy流に下＋右へ展開）。
    /// カーソルのあるスクリーンの visibleFrame 内にクランプして画面外へはみ出さないようにする。
    /// パネルは固定高（1ページ=10件）なので、件数が増えてもこのクランプは常に成立する。
    private func positionAtMouse(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation   // グローバル座標（左下原点）
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        // origin は左下基準。top をカーソルに合わせる＝ origin.y = mouse.y - height。
        let x = min(max(mouse.x, vf.minX), vf.maxX - size.width)
        let y = min(max(mouse.y - size.height, vf.minY), vf.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
