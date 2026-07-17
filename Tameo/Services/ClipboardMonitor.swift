import AppKit
import Observation
import PDFKit

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
    /// 種別ごとの保存トグル・機密除外の参照元。
    private let settings: SettingsStore
    private let pasteboard: NSPasteboard = .general
    private var lastChangeCount: Int
    private var timer: Timer?
    /// ポーリング間隔（秒）。100〜500ms が実用域。
    var pollInterval: TimeInterval = 0.4

    /// 画像原本を保持する上限。超過時は原本を破棄しサムネ＋メタのみ残す（payloadTruncated=true）。
    ///
    /// 注: `NSPasteboardItem` にはサイズを事前に問い合わせる API が無く、`data(forType:)` は
    /// 常に全バイトをプロセスへコピーする。したがってこの上限は「読む前の門」にはできず、
    /// 読んだ後の**永続化と重いパースの門**として機能する（超過時は原本を捨て、RTF 平文化や
    /// PDF 解析もスキップする）。デコード爆弾に効くのはバイト数ではなくピクセル数の上限で、
    /// そちらは `OCRService.maxPixelSize` と `thumbnailMaxPixel` が担当する。
    static let maxOriginalBytes = 8 * 1024 * 1024
    /// 履歴に残すテキストの上限バイト数（UTF-8）。
    /// これを超える文字列は履歴に入れない。行として保持すると DB を肥大させるうえ、
    /// 検索インデックスの正規化（NFKC＋かな畳み込み）が main を長時間塞ぐため。
    /// クリップボード自体は無傷なので、ユーザーは通常どおり手で貼り付けられる。
    static let maxTextBytes = 8 * 1024 * 1024
    /// 一覧サムネの最長辺ピクセル。
    static let thumbnailMaxPixel = 128
    /// 直近 1 tick の間に前面だったアプリの bundle id（除外判定の取りこぼし防止）。
    ///
    /// コピーの発生時刻は知りようがなく、検知は最大 `pollInterval`＋tolerance（~0.48s）遅れる。
    /// その間にユーザーがアプリを切り替えると「検知時点の前面」はコピー元ではない。
    /// 期間中に前面だったアプリを全部覚えておき、1 つでも除外対象なら安全側に倒して取り込まない。
    private var frontmostSinceLastTick: Set<String> = []
    /// 前面アプリ切替の監視トークン（`start()` 中だけ有効）。
    private var activationObserver: NSObjectProtocol?

    init(store: HistoryStore, gate: PasteboardWriteGate, settings: SettingsStore) {
        self.store = store
        self.gate = gate
        self.settings = settings
        // 起動時点の既存クリップは無視する。
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        // 除外判定の窓を今の前面アプリで初期化する。
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            frontmostSinceLastTick.insert(front)
        }
        // 前面アプリの切替を拾い、tick 間に経由したアプリを取りこぼさない（bundle id のみ・内容は読まない）。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                self?.frontmostSinceLastTick.insert(id)
            }
        }
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
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        frontmostSinceLastTick.removeAll()
    }

    private func tick() {
        // 除外判定の窓は 1 tick ぶんだけ保持する。今回ぶんを取り出し、次回用に現在の前面で撒き直す。
        let recentFrontmost = frontmostSinceLastTick
        defer {
            frontmostSinceLastTick.removeAll()
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                frontmostSinceLastTick.insert(front)
            }
        }

        // changeCount の読み取りは内容を晒さず、プライバシー警告も出さない。
        let change = pasteboard.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change
        // コピー時刻の最良近似。以降の並び順はこの時刻を基準にする（挿入時刻ではなく）。
        let capturedAt = Date.now

        // 自分（Tameo の貼り戻し/コピー）が起こした変化は取り込まない＝重複行を防ぐ。
        if gate.isSelfWrite(changeCount: change) { return }

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        // 除外マーカー判定は「アイテム単位の types」で行う（集約 types では誤判定する）。
        // データ読み取りの **前** に弾く（プライバシー据え置き）。
        for item in items {
            let types = Set(item.types)
            // 機密(ConcealedType)/一時/自動生成は設定に関わらず常に無視する（無効化手段は持たせない）。
            if !alwaysIgnoredMarkerTypes.isDisjoint(with: types) {
                return
            }
        }

        // コピー元の判定。内容を読む前に確定させる（bundle id の比較のみで中身は読まない）。
        let origin = resolveOrigin(items: items, recentFrontmost: recentFrontmost)
        guard !origin.isExcluded(by: settings.excludedBundleIDs) else { return }

        // ==== Tameo の背景経路で内容を読む唯一の箇所 ====
        // まず型集合（中身を読まない）で種別を判定し、勝った型だけを 1 回読む。
        var allTypes = Set<NSPasteboard.PasteboardType>()
        for item in items { allTypes.formUnion(item.types) }
        let kind = ClipKind.detect(types: allTypes)

        // 種別ごとの保存トグル（既定すべて true）。無効種別はここで弾く＝内容を読まない／
        // 画像の Task.detached も起動しない（プライバシー・余計な処理を増やさない）。
        guard settings.isStoreEnabled(kind) else { return }

        switch kind {
        case .png, .tiff:
            // 画像はサムネ生成・寸法読取を off-main で行うため非同期経路。
            captureImage(items: items, kind: kind, source: origin.bundleID, capturedAt: capturedAt)
        default:
            if let payload = classify(kind: kind, items: items, source: origin.bundleID, capturedAt: capturedAt) {
                store.ingest(payload)
            }
        }
        // ===============================================
    }

    /// コピー元の判定結果。履歴に残す出所と、除外判定にかける候補集合を持つ。
    private struct CopyOrigin {
        /// 履歴へ記録する出所（最有力の 1 つ）。不明なら nil。
        let bundleID: String?
        /// 除外判定の対象となる候補すべて。
        let candidates: Set<String>

        func isExcluded(by excluded: [String]) -> Bool {
            guard !excluded.isEmpty else { return false }
            return !candidates.isDisjoint(with: Set(excluded))
        }
    }

    /// コピー元を決める。
    ///
    /// 優先: `org.nspasteboard.source`。コピーした側がペーストボードへ明示的に載せた出所なので、
    ///       アプリ切替のタイミングに一切左右されない（＝競合しない）。これがあればこれだけで判定する。
    ///       読むのは bundle id の文字列マーカーのみで、ユーザーの内容ではない。
    /// 代替: 前面アプリ。ただし検知は最大 ~0.48s 遅れるため、単一時点の前面は取り違える
    ///       （除外アプリでコピー → 即 Safari へ切替 → Safari 由来と誤判定して保存、など）。
    ///       そこで除外判定には「直近 1 tick に前面だったアプリ」を全部かけ、1 つでも該当したら
    ///       取り込まない＝安全側へ倒す。誤って弾く側（通常アプリのコピーが捨てられる）は
    ///       利便性の損失で済むが、誤って保存する側は機密の漏出になるため対称に扱わない。
    private func resolveOrigin(items: [NSPasteboardItem], recentFrontmost: Set<String>) -> CopyOrigin {
        for item in items {
            if let declared = item.string(forType: .source), !declared.isEmpty {
                return CopyOrigin(bundleID: declared, candidates: [declared])
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var candidates = recentFrontmost
        if let front { candidates.insert(front) }
        return CopyOrigin(bundleID: front, candidates: candidates)
    }

    /// 同期取り込み。種別ごとに対応経路を 1 回読む。各 capture が失敗したらテキスト表現へフォールバック。
    private func classify(kind: ClipKind, items: [NSPasteboardItem], source: String?, capturedAt: Date) -> CapturedPayload? {
        switch kind {
        case .filename:
            return captureFilenames(items: items, source: source, capturedAt: capturedAt)
                ?? textFallback(items: items, source: source, capturedAt: capturedAt)
        case .url:
            return captureURL(items: items, source: source, capturedAt: capturedAt)
                ?? textFallback(items: items, source: source, capturedAt: capturedAt)
        case .color:
            return captureColor(source: source, capturedAt: capturedAt)
                ?? textFallback(items: items, source: source, capturedAt: capturedAt)
        case .rtf, .rtfd, .pdf:
            return captureRichData(kind: kind, items: items, source: source, capturedAt: capturedAt)
                ?? textFallback(items: items, source: source, capturedAt: capturedAt)
        default:
            return textFallback(items: items, source: source, capturedAt: capturedAt)
        }
    }

    /// テキスト表現があればそれを取り込む（各種別捕捉のフォールバック）。
    /// 内容が色コード（#RGB/#RRGGBB/rgb(...)）なら `.color` へ昇格させる（チップ表示＋色対応アプリへの貼付）。
    /// `.color` の貼付は content 文字列も併載するため、テキストエディタ等には元の文字列がそのまま貼られる。
    private func textFallback(items: [NSPasteboardItem], source: String?, capturedAt: Date) -> CapturedPayload? {
        for item in items {
            if let text = item.string(forType: .string), !text.isEmpty {
                // 巨大テキストは履歴に入れない（DB 肥大と検索インデックス正規化による main 停止を防ぐ）。
                // 他アプリは同意なくペーストボードへ任意サイズの文字列を置けるため、上限は必須。
                guard text.utf8.count <= Self.maxTextBytes else {
                    NSLog("Tameo: skipped oversized text clip (%d bytes > %d)", text.utf8.count, Self.maxTextBytes)
                    return nil
                }
                if let hex = ColorCode.normalizedHex(from: text) {
                    return .color(code: text, hex: hex, source: source, capturedAt: capturedAt)
                }
                return .text(text, source: source, capturedAt: capturedAt)
            }
        }
        return nil
    }

    /// file URL を読み、パス文字列＋先頭ファイルのアイコンから filename ペイロードを作る。
    /// `readObjects` の投機的多重実行はせず、項目ごとの `string(forType:.fileURL)` で 1 経路に留める。
    private func captureFilenames(items: [NSPasteboardItem], source: String?, capturedAt: Date) -> CapturedPayload? {
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
            byteSize: displayPaths.utf8.count,
            capturedAt: capturedAt
        )
    }

    /// 非ファイル URL（.URL 型）。content=URL 文字列。
    private func captureURL(items: [NSPasteboardItem], source: String?, capturedAt: Date) -> CapturedPayload? {
        for item in items {
            if let s = item.string(forType: .URL), !s.isEmpty {
                return CapturedPayload(
                    kind: .url, content: s, payloadUTI: ClipKind.url.preferredUTI,
                    canonicalBytes: Data(s.utf8), sourceBundleID: source, byteSize: s.utf8.count,
                    capturedAt: capturedAt
                )
            }
        }
        return nil
    }

    /// 色（NSColor 型）。content=#RRGGBB。勝った型（color）のみを 1 回読む。
    private func captureColor(source: String?, capturedAt: Date) -> CapturedPayload? {
        guard let colors = pasteboard.readObjects(forClasses: [NSColor.self], options: nil) as? [NSColor],
              let color = colors.first else { return nil }
        let hex = color.tameoHexString
        return CapturedPayload(
            kind: .color, content: hex, payloadUTI: ClipKind.color.preferredUTI,
            canonicalBytes: Data(hex.utf8), colorHex: hex, sourceBundleID: source, byteSize: hex.utf8.count,
            capturedAt: capturedAt
        )
    }

    /// リッチデータ（rtf/rtfd/pdf）。原本を payloadData(externalStorage) に格納し、
    /// content は表示・検索・平文貼付用ラベル（rtf/rtfd=平文化／pdf=ページ数）。8MB 上限で原本破棄。
    private func captureRichData(kind: ClipKind, items: [NSPasteboardItem], source: String?, capturedAt: Date) -> CapturedPayload? {
        let pbType: NSPasteboard.PasteboardType
        switch kind {
        case .rtf: pbType = .rtf
        case .rtfd: pbType = .rtfd
        case .pdf: pbType = .pdf
        default: return nil
        }
        var data: Data?
        for item in items {
            if let d = item.data(forType: pbType), !d.isEmpty { data = d; break }
        }
        guard let data else { return nil }

        let truncated = data.count > Self.maxOriginalBytes
        // 原本破棄が確定する大データは、main をブロックする重いパース（rtf 平文化 / pdf 解析）を避け汎用ラベルにする。
        let label = truncated ? Self.genericLabel(kind: kind) : Self.richLabel(kind: kind, data: data)
        guard !label.isEmpty else { return nil }

        let payloadData: Data? = truncated ? nil : data
        // 重複排除キー: 通常は原本バイト。原本破棄時はラベル＋サイズで衝突回避。
        let canonical = payloadData ?? Data("\(label)\u{0}\(data.count)".utf8)

        return CapturedPayload(
            kind: kind, content: label, payloadUTI: kind.preferredUTI,
            canonicalBytes: canonical, payloadData: payloadData, payloadTruncated: truncated,
            sourceBundleID: source, byteSize: data.count, capturedAt: capturedAt
        )
    }

    /// パースを伴わない汎用ラベル（8MB 超で原本破棄が確定した場合に使う）。
    private static func genericLabel(kind: ClipKind) -> String {
        switch kind {
        case .rtf: return "RTF"
        case .rtfd: return "RTFD"
        case .pdf: return "PDF"
        default: return ""
        }
    }

    /// リッチデータの表示ラベル（rtf/rtfd=平文化、pdf=ページ数）。
    private static func richLabel(kind: ClipKind, data: Data) -> String {
        switch kind {
        case .rtf, .rtfd:
            let docType: NSAttributedString.DocumentType = (kind == .rtf) ? .rtf : .rtfd
            let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: docType],
                documentAttributes: nil
            )
            let plain = (attr?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? (kind == .rtf ? "RTF" : "RTFD") : plain
        case .pdf:
            let pages = PDFDocument(data: data)?.pageCount ?? 0
            return pages > 0 ? "PDF · \(pages) page\(pages == 1 ? "" : "s")" : "PDF"
        default:
            return ""
        }
    }

    /// 画像（png/tiff）を捕捉。raw を main で取得し、サムネ生成＋ピクセル寸法は `Task.detached` で行い、
    /// MainActor へ戻して取り込む。NSImage/CGImage はこの境界を越えない（CapturedPayload は値型のみ）。
    /// 貼り戻し由来の自己コピーは tick の gate 判定で既に弾かれている。
    ///
    /// 着地が遅れても順序は `capturedAt`（検知時刻）が担保するため、以前あった changeCount の
    /// 単調ガードは持たない。あのガードは「遅れて着地した画像を捨てる」もので、順序の不整合を
    /// データ損失に置き換えてしまう（画像Aをコピーした直後にテキストBをコピーすると A が消える）。
    private func captureImage(items: [NSPasteboardItem], kind: ClipKind, source: String?, capturedAt: Date) {
        let pbType: NSPasteboard.PasteboardType = (kind == .png) ? .png : .tiff
        var raw: Data?
        for item in items {
            if let d = item.data(forType: pbType), !d.isEmpty { raw = d; break }
        }
        guard let raw else { return }

        let truncated = raw.count > Self.maxOriginalBytes
        let payloadData: Data? = truncated ? nil : raw
        let uti = kind.preferredUTI
        let label = (kind == .png) ? "PNG" : "TIFF"

        Task.detached(priority: .utility) {
            let thumb = ImageThumbnailer.thumbnailPNG(from: raw, maxPixel: Self.thumbnailMaxPixel)
            let (w, h) = ImageThumbnailer.pixelSize(of: raw) ?? (0, 0)
            // 重複排除キーの入力バイト。通常は原本。原本破棄(truncated)時は空 Data 衝突を避けるため
            // サムネへフォールバックし、さらに寸法・原本サイズを混ぜて別の巨大画像が同一サムネで衝突しないようにする。
            let canonical: Data
            if let payloadData {
                canonical = payloadData
            } else if let thumb {
                canonical = thumb + Data("\(w)x\(h)x\(raw.count)".utf8)
            } else {
                canonical = raw
            }
            let content = "Image · \(w)×\(h) · \(label)"
            let payload = CapturedPayload(
                kind: kind,
                content: content,
                payloadUTI: uti,
                canonicalBytes: canonical,
                payloadData: payloadData,
                thumbnailPNG: thumb,
                pixelWidth: w,
                pixelHeight: h,
                payloadTruncated: truncated,
                sourceBundleID: source,
                byteSize: raw.count,
                capturedAt: capturedAt
            )
            await self.ingest(payload)
        }
    }

    /// detached から MainActor へ戻して取り込む。
    private func ingest(_ payload: CapturedPayload) {
        store.ingest(payload)
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
