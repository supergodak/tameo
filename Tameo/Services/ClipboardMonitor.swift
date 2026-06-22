import AppKit
import Observation

/// クリップボードの変化を監視する唯一のオブジェクト。
/// 背景動作で `NSPasteboard.general` に触れるのはここだけ。
/// 変化検知は `changeCount`（内容を読まない・警告を出さない）で行い、
/// 内容の読み出しは「履歴に残すテキスト1回」だけに限定する（下記チョークポイント）。
@MainActor
@Observable
final class ClipboardMonitor {
    private let store: HistoryStore
    private let pasteboard: NSPasteboard = .general
    private var lastChangeCount: Int
    private var timer: Timer?
    /// ポーリング間隔（秒）。100〜500ms が実用域。
    var pollInterval: TimeInterval = 0.4

    init(store: HistoryStore) {
        self.store = store
        // 起動時点の既存クリップは無視する。
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            // タイマーはメインランループで発火するため、メイン分離を明示して呼ぶ。
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        t.tolerance = pollInterval * 0.2
        // メニュー表示中（イベントトラッキング）でも発火するよう .common に追加。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // changeCount の読み取りは内容を晒さず、プライバシー警告も出さない。
        let change = pasteboard.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        // 除外マーカー判定は「アイテム単位の types」で行う（集約 types では誤判定する）。
        for item in items {
            let types = Set(item.types)
            if !ignoredMarkerTypes.isDisjoint(with: types) {
                return // 機密/一時/自動生成 → この変更は丸ごと無視
            }
        }

        // ==== Tameo の背景経路で内容を読む唯一の箇所 ====
        // Apple がペーストボード・プライバシーを強制化した場合、ゲートするのはここ。
        for item in items {
            if let text = item.string(forType: .string), !text.isEmpty {
                store.ingest(text: text, sourceBundleID: nil, isConcealed: false)
                return
            }
        }
        // ===============================================
    }
}
