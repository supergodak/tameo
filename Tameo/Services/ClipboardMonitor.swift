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
    static let maxOriginalBytes = 8 * 1024 * 1024
    /// 一覧サムネの最長辺ピクセル。
    static let thumbnailMaxPixel = 128
    /// 画像の非同期取り込みで、古い結果が新しい結果の後に着地しないための単調ガード。
    private var latestAppliedImageChange = 0

    init(store: HistoryStore, gate: PasteboardWriteGate, settings: SettingsStore) {
        self.store = store
        self.gate = gate
        self.settings = settings
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
            // 一時/自動生成は常に無視。機密(ConcealedType)は設定 ignoreConcealed が有効なときだけ無視。
            if !alwaysIgnoredMarkerTypes.isDisjoint(with: types) {
                return
            }
            if settings.ignoreConcealed && types.contains(.concealed) {
                return
            }
        }

        // 助言用のコピー元（concealed 判定には使わない／ペーストボードは読まない）。
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 除外アプリが前面のときは取り込まない（内容を読む前に弾く）。bundle id の比較のみで中身は読まない。
        // source=nil（前面不明/bundle id 無し）は突き合わせ不能のため取り込む（従来どおり）。機密遮断は上の ConcealedType ゲートが担当。
        if let source, settings.excludedBundleIDs.contains(source) { return }

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
            captureImage(items: items, kind: kind, source: source, changeCount: change)
        default:
            if let payload = classify(kind: kind, items: items, source: source) {
                store.ingest(payload)
            }
        }
        // ===============================================
    }

    /// 同期取り込み。種別ごとに対応経路を 1 回読む。各 capture が失敗したらテキスト表現へフォールバック。
    private func classify(kind: ClipKind, items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
        switch kind {
        case .filename:
            return captureFilenames(items: items, source: source) ?? textFallback(items: items, source: source)
        case .url:
            return captureURL(items: items, source: source) ?? textFallback(items: items, source: source)
        case .color:
            return captureColor(source: source) ?? textFallback(items: items, source: source)
        case .rtf, .rtfd, .pdf:
            return captureRichData(kind: kind, items: items, source: source) ?? textFallback(items: items, source: source)
        default:
            return textFallback(items: items, source: source)
        }
    }

    /// テキスト表現があればそれを取り込む（各種別捕捉のフォールバック）。
    private func textFallback(items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
        for item in items {
            if let text = item.string(forType: .string), !text.isEmpty {
                return .text(text, source: source)
            }
        }
        return nil
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

    /// 非ファイル URL（.URL 型）。content=URL 文字列。
    private func captureURL(items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
        for item in items {
            if let s = item.string(forType: .URL), !s.isEmpty {
                return CapturedPayload(
                    kind: .url, content: s, payloadUTI: ClipKind.url.preferredUTI,
                    canonicalBytes: Data(s.utf8), sourceBundleID: source, byteSize: s.utf8.count
                )
            }
        }
        return nil
    }

    /// 色（NSColor 型）。content=#RRGGBB。勝った型（color）のみを 1 回読む。
    private func captureColor(source: String?) -> CapturedPayload? {
        guard let colors = pasteboard.readObjects(forClasses: [NSColor.self], options: nil) as? [NSColor],
              let color = colors.first else { return nil }
        let hex = color.tameoHexString
        return CapturedPayload(
            kind: .color, content: hex, payloadUTI: ClipKind.color.preferredUTI,
            canonicalBytes: Data(hex.utf8), colorHex: hex, sourceBundleID: source, byteSize: hex.utf8.count
        )
    }

    /// リッチデータ（rtf/rtfd/pdf）。原本を payloadData(externalStorage) に格納し、
    /// content は表示・検索・平文貼付用ラベル（rtf/rtfd=平文化／pdf=ページ数）。8MB 上限で原本破棄。
    private func captureRichData(kind: ClipKind, items: [NSPasteboardItem], source: String?) -> CapturedPayload? {
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
            sourceBundleID: source, byteSize: data.count
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
    /// changeCount 単調ガード付きで MainActor へ戻して取り込む。NSImage/CGImage はこの境界を越えない
    /// （CapturedPayload は値型のみ）。貼り戻し由来の自己コピーは tick の gate 判定で既に弾かれている。
    private func captureImage(items: [NSPasteboardItem], kind: ClipKind, source: String?, changeCount: Int) {
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
                byteSize: raw.count
            )
            await self.ingestImageIfCurrent(payload, changeCount: changeCount)
        }
    }

    /// 単調ガード: より新しい変化を既に取り込んでいたら、この（古い）非同期結果は捨てる。
    private func ingestImageIfCurrent(_ payload: CapturedPayload, changeCount: Int) {
        guard changeCount >= latestAppliedImageChange else { return }
        latestAppliedImageChange = changeCount
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
