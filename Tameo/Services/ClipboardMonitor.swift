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
    /// 自己コピー抑止ゲート（貼り戻し由来の重複行を防ぐ）。
    private let gate: PasteboardWriteGate
    private let pasteboard: NSPasteboard = .general
    private var lastChangeCount: Int
    private var timer: Timer?
    /// ポーリング間隔（秒）。100〜500ms が実用域。
    var pollInterval: TimeInterval = 0.4

    init(store: HistoryStore, gate: PasteboardWriteGate) {
        self.store = store
        self.gate = gate
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

        // 自分（Tameo の貼り戻し/コピー）が起こした変化は取り込まない＝重複行を防ぐ。
        if gate.isSelfWrite(changeCount: change) { return }

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        // 除外マーカー判定は「アイテム単位の types」で行う（集約 types では誤判定する）。
        // データ読み取りの **前** に弾く（プライバシー据え置き）。
        for item in items {
            let types = Set(item.types)
            if !ignoredMarkerTypes.isDisjoint(with: types) {
                return // 機密/一時/自動生成 → この変更は丸ごと無視
            }
        }

        // 助言用のコピー元（concealed 判定には使わない／ペーストボードは読まない）。
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // ==== Tameo の背景経路で内容を読む唯一の箇所 ====
        // まず型集合（中身を読まない）で種別を判定し、勝った型だけを 1 回読む。
        if let payload = classify(items: items, source: source) {
            store.ingest(payload)
        }
        // ===============================================
    }

    /// 型集合で種別を判定→対応する 1 経路だけ内容を読む。PR-A は filename と text を実装
    /// （画像/リッチは PR-B/C）。未対応の binary はテキスト表現があればそれを取り込む。
    private func classify(items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
        var allTypes = Set<NSPasteboard.PasteboardType>()
        for item in items { allTypes.formUnion(item.types) }

        switch ClipKind.detect(types: allTypes) {
        case .filename:
            return captureFilenames(items: items, source: source)
        default:
            for item in items {
                if let text = item.string(forType: .string), !text.isEmpty {
                    return .text(text, source: source)
                }
            }
            return nil
        }
    }

    /// file URL を読み、パス文字列＋先頭ファイルのアイコンから filename ペイロードを作る。
    /// `readObjects` の投機的多重実行はせず、項目ごとの `string(forType:.fileURL)` で 1 経路に留める。
    private func captureFilenames(items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
        var paths: [String] = []
        var urlStrings: [String] = []
        for item in items {
            guard let urlString = item.string(forType: .fileURL),
                  let url = URL(string: urlString), url.isFileURL else { continue }
            paths.append(url.path)
            urlStrings.append(url.absoluteString)
        }
        guard !paths.isEmpty else { return nil }

        // content = 表示＆パス文字列ペースト用（人が読むパス）。
        // fileURLStrings = 復元用（absoluteString は改行を % エンコードするため \n 分割が安全。
        // パス自体に改行を含む稀なファイル名でも往復が壊れない）。
        let displayPaths = paths.joined(separator: "\n")
        let urlList = urlStrings.joined(separator: "\n")
        let thumb = Self.fileIconPNG(forPath: paths[0])
        return CapturedPayload(
            kind: .filename,
            content: displayPaths,
            payloadUTI: ClipKind.filename.preferredUTI,
            canonicalBytes: Data(displayPaths.utf8),
            thumbnailPNG: thumb,
            fileURLStrings: urlList,
            sourceBundleID: source,
            byteSize: displayPaths.utf8.count
        )
    }

    /// ファイルアイコンを小さな PNG にして返す（行描画での disk hit を避けるため取り込み時に 1 回だけ解決）。
    private static func fileIconPNG(forPath path: String, maxPixel: CGFloat = 32) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let target = NSSize(width: maxPixel, height: maxPixel)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: target),
                  from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
