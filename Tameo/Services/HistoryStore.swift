import Foundation
import SwiftData
import Observation

/// 履歴の保存・取り出し口。M1の唯一の書き込み主体。すべて MainActor 上で動く。
/// - 内容の実読み出し（`item.string(forType:)`）は `ClipboardMonitor` の1箇所に隔離してある。
///   ここはそこから渡されたテキストを受け取って永続化するだけ（プライバシー上クリーン）。
@MainActor
@Observable
final class HistoryStore {
    private let modelContext: ModelContext
    /// 履歴の最大保持数の真実源（設定で可変）。超過分は古い順に削除。
    private let settings: SettingsStore
    /// 一度きり移行（backfill/dedupe/encrypt）の完了フラグ置き場。
    /// テストは使い捨てスイートを注入し、実 `.standard` を汚さない（v0.1.9 の教訓）。
    private let flagDefaults: UserDefaults

    init(modelContext: ModelContext, settings: SettingsStore, flagDefaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.settings = settings
        self.flagDefaults = flagDefaults
    }

    /// 監視側が組み立てた捕捉ペイロードを履歴へ取り込む（全種別共通の入口）。
    /// 重複判定は `contentHash` で行う（テキストの文字列一致を全種別へ一般化したもの）。
    func ingest(_ payload: CapturedPayload) {
        guard !payload.isConcealed else { return }
        guard payload.byteSize > 0 else { return }

        let hash = HistoryVault.blindIndexHex(payload.canonicalBytes)

        // レガシ行（M3 前）は contentHash が空。全体検索の前に最新行だけ一度補完する
        // （アップグレード後の初回再コピーで重複が出るのを全移行なしで防ぐ）。
        if let newest = newestItem(), newest.contentHash.isEmpty {
            newest.contentHash = HistoryVault.blindIndexHex(canonicalBytes(of: newest))
        }

        // 全体重複排除（bump-to-top）: 履歴の「どこか」に同種別・同内容の既存項目があれば、
        // 新規行を作らず既存項目を「今使った」ことにして先頭へ繰り上げる（Clipy 相当）。
        // 直前1件だけでなく全体を見るので、A→B→A のように別物を挟んだ再コピーでも重複しない。
        // 種別も一致条件に含めるため、同じパス文字列でも「テキスト行」と「実ファイルの filename 行」は
        // 別物として扱い、ハッシュ衝突で filename 捕捉（アイコン/ファイル参照）を取りこぼさない。
        if let existing = existingItem(kindRaw: payload.kind.rawValue, contentHash: hash) {
            // 検知時刻で繰り上げる。ただし遅れて着地した非同期取り込み（画像）が、既により新しい
            // 使用時刻を持つ行を過去へ引き戻さないよう単調に保つ。
            existing.lastUsedAt = max(existing.lastUsedAt, payload.capturedAt)
            save()
            return
        }

        let item = ClipboardItem(payload: payload, contentHash: hash)
        modelContext.insert(item)
        prune()
        save()
        scheduleOCRIfNeeded(item)
    }

    /// 既存テキスト経路は薄いラッパとして温存（呼び出し側はバイト等価）。
    func ingest(text: String, sourceBundleID: String?, isConcealed: Bool) {
        guard !isConcealed, !text.isEmpty else { return }
        ingest(CapturedPayload.text(text, source: sourceBundleID))
    }

    /// 既存行の重複排除キー入力バイト（backfill 用）。binary は payloadData、無ければ thumbnailPNG、最後に content。
    private func canonicalBytes(of item: ClipboardItem) -> Data {
        if item.kind.hasBinaryPayload {
            return item.payloadData ?? item.thumbnailPNG ?? Data(item.content.utf8)
        }
        return Data(item.content.utf8)
    }

    /// 既存項目を「今使った」ことにして先頭へ（M2のペースト後移動でも使用）。
    func markUsed(_ item: ClipboardItem) {
        item.lastUsedAt = .now
        save()
    }

    // MARK: - OCR（画像のオンデバイス文字認識）

    /// OCR 実行中の項目（同一項目の二重実行を防ぐ）。
    private var ocrInFlight: Set<PersistentIdentifier> = []

    /// 画像（ピクセル）／画像ファイルを指す filename に対してバックグラウンドで OCR を起動する。
    /// 取り込みは止めず、完了後に `ocrText` と `searchIndex` を更新する。
    func scheduleOCRIfNeeded(_ item: ClipboardItem) {
        guard settings.ocrEnabled, !item.ocrProcessed else { return }
        let id = item.persistentModelID
        guard !ocrInFlight.contains(id) else { return }

        if item.kind.isImage {
            // 画像ピクセル（png/tiff）: 原本（無ければサムネ）をOCR。
            guard let data = item.payloadData ?? item.thumbnailPNG else { return }
            ocrInFlight.insert(id)
            Task { [weak self] in
                let text = await OCRService.recognizeText(in: data)
                self?.applyOCR(id: id, text: text ?? "")
            }
        } else if item.kind == .filename, let url = item.fileURLs.first(where: Self.isImageFile) {
            // コピーされたパスが画像ファイルを指す: そのファイルを読んでOCR（スクショのファイルコピー対応）。
            ocrInFlight.insert(id)
            Task { [weak self] in
                let text = await OCRService.recognizeText(inFileAt: url)
                self?.applyOCR(id: id, text: text ?? "")
            }
        }
    }

    /// 渡された一覧のうち未処理項目に遅延 OCR をかける（種別判定は scheduleOCRIfNeeded 内）。
    func recognizeMissing(in items: [ClipboardItem]) {
        guard settings.ocrEnabled else { return }
        for item in items where !item.ocrProcessed {
            scheduleOCRIfNeeded(item)
        }
    }

    /// OCR 対象とみなす画像ファイル拡張子。
    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp",
    ]
    private static func isImageFile(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// OCR 結果を反映（detached からは ID だけ渡し、ここで引き直して書き込む＝アクター越え安全）。
    private func applyOCR(id: PersistentIdentifier, text: String) {
        ocrInFlight.remove(id)
        guard let item = modelContext.model(for: id) as? ClipboardItem else { return }
        item.ocrText = text
        item.ocrProcessed = true
        item.searchIndex = item.searchableSourceText
        save()
    }

    /// 項目のピン留め状態を切り替える。ピンは一覧最上段に固定し、prune から保護される。
    func setPinned(_ item: ClipboardItem, _ pinned: Bool) {
        item.isPinned = pinned
        save()
    }

    /// 履歴を検索する。種別フィルタは DB 側の述語、**テキスト照合は復号済み索引のメモリ内**で行い、
    /// 上位 `limit` 件を返す。
    ///
    /// 索引（`searchIndex`）は保存時暗号化の対象なので `#Predicate` では照合できない。
    /// 全件（保持上限＝既定 200・最大 1000）をフェッチして復号索引で絞る。復号は項目ごとに
    /// `@Transient` キャッシュされるため、毎キーストロークの実コストは文字列 contains のみ。
    /// 「全履歴が検索対象」（101 件目以降も見つかる）という 0.1.10 の保証は変わらない。
    ///
    /// - Parameters:
    ///   - query: 生のクエリ。ここで索引と同じ規則へ正規化する（全角/かな/大小の揺れを吸収）。
    ///   - kinds: 空なら全種別。
    func searchHistory(query: String, kinds: Set<ClipKind>, sortOrder: HistorySortOrder,
                       limit: Int) -> [ClipboardItem] {
        let sort: [SortDescriptor<ClipboardItem>]
        switch sortOrder {
        case .lastUsed: sort = [SortDescriptor(\.lastUsedAt, order: .reverse)]
        case .createdAt: sort = [SortDescriptor(\.createdAt, order: .reverse)]
        }
        let q = SearchNormalizer.normalize(query)
        let kindRaws = kinds.map(\.rawValue)

        var d: FetchDescriptor<ClipboardItem>
        if kindRaws.isEmpty {
            d = FetchDescriptor<ClipboardItem>(sortBy: sort)
        } else {
            d = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { kindRaws.contains($0.kindRaw) }, sortBy: sort)
        }
        if q.isEmpty {
            d.fetchLimit = limit
            return (try? modelContext.fetch(d)) ?? []
        }
        guard let all = try? modelContext.fetch(d) else { return [] }
        return Array(all.lazy.filter { $0.searchIndex.contains(q) }.prefix(limit))
    }

    /// 履歴から 1 項目だけ削除する（パレットの ⌘⌫）。
    /// `clearAll` と同じ理由でオブジェクト単位に削除し、externalStorage の sidecar も片付ける。
    func delete(_ item: ClipboardItem) {
        modelContext.delete(item)
        save()
    }

    /// 全履歴を消去（メニューの「履歴をクリア」用）。
    /// 書き込み（insert/delete/save）は本クラスに一本化する設計のため、View直叩きではなくここを呼ぶ。
    func clearAll() {
        // batch delete（delete(model:)）は externalStorage の sidecar を消さず、画像原本ファイルが孤児化する。
        // オブジェクト単位で削除して per-object のクリーンアップ（sidecar 削除）を走らせる。
        do {
            let items = try modelContext.fetch(FetchDescriptor<ClipboardItem>())
            for item in items { modelContext.delete(item) }
            try modelContext.save()
        } catch {
            NSLog("Tameo: clear all failed: %@", String(describing: error))
        }
    }

    /// 既存（M5前）の全行に検索インデックスを一度だけ補完する。起動時に1回呼ぶ。
    /// 数百〜数千件規模なら同期パスで十分。`UserDefaults` のフラグで再実行を防ぐ。
    ///
    /// フラグは**実際に成功したときだけ**立てる。fetch や save が失敗したのに「補完済み」に
    /// してしまうと二度と走らず、対象行は永久に検索へ現れなくなる（`searchIndex` が空の行は
    /// どのクエリにもヒットしない）。一時的な DB エラーを恒久的な機能欠損に変えないため、
    /// 失敗時はフラグを立てずに次回起動で再試行させる。
    func backfillSearchIndexIfNeeded() {
        let key = "tameo.searchIndex.backfilled"
        guard !flagDefaults.bool(forKey: key) else { return }
        // searchIndex は暗号化アクセサ（computed）になったため #Predicate では絞れない。
        // 全件フェッチして復号索引でメモリ内判定する（保持上限規模なので同期パスで十分）。
        guard let all = try? modelContext.fetch(FetchDescriptor<ClipboardItem>()) else {
            NSLog("Tameo: searchIndex backfill fetch failed; 次回起動で再試行します")
            return
        }
        let items = all.filter { $0.searchIndex.isEmpty }
        if !items.isEmpty {
            for item in items {
                item.searchIndex = item.searchableSourceText
            }
            guard save() else {
                NSLog("Tameo: searchIndex backfill save failed; 次回起動で再試行します")
                return
            }
        }
        flagDefaults.set(true, forKey: key)
    }

    /// 既存履歴に溜まった重複行を一度だけ掃除する（bump-to-top 導入前に積まれた分の後始末）。起動時に1回呼ぶ。
    /// 同種別・同内容ハッシュのグループごとに最新1件だけ残し、古い重複は削除する（ピン留めは削除しない）。
    /// レガシ行は contentHash が空なので、グループ化の前に必ず補完する（空同士の誤マージを防ぐ）。
    /// フラグは**実際に成功したときだけ**立てる（`backfillSearchIndexIfNeeded` と同じ理由）。
    /// 以前は `defer` で立てていたため、fetch 失敗の早期 return でも「掃除済み」が確定し、
    /// 一時的な DB エラーで掃除が永久に走らなくなっていた。
    func dedupeExistingHistoryIfNeeded() {
        let key = "tameo.history.deduped.v1"
        guard !flagDefaults.bool(forKey: key) else { return }

        // 新しい順に走査し、初めて見た (種別+ハッシュ) を残し、以降の同一キーは削除する。
        let d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        guard let items = try? modelContext.fetch(d) else {
            NSLog("Tameo: dedupe fetch failed; 次回起動で再試行します")
            return
        }

        var seen = Set<String>()
        var changed = false
        for item in items {
            if item.contentHash.isEmpty {
                item.contentHash = HistoryVault.blindIndexHex(canonicalBytes(of: item))
                changed = true                      // ハッシュ補完だけでも保存対象
            }
            let groupKey = item.kindRaw + "\u{0}" + item.contentHash
            if seen.contains(groupKey) {
                // 既に同一内容のより新しい行を残している。古い重複を削除（ただしピンは温存）。
                if item.isPinned { continue }
                modelContext.delete(item)
                changed = true
            } else {
                seen.insert(groupKey)
            }
        }
        if changed {
            guard save() else {
                NSLog("Tameo: dedupe save failed; 次回起動で再試行します")
                return
            }
        }
        flagDefaults.set(true, forKey: key)
    }

    /// 既存の平文履歴を一度だけ暗号化する（保存時暗号化の導入移行）。起動時に、他の一度きり処理より先に呼ぶ。
    ///
    /// - 触る前に SQLite Backup API でストアを丸ごと退避する（v0.1.8 のデータ消失事故の教訓。
    ///   `storeURL` が nil のとき＝インメモリテストではスキップ）。
    /// - 各フィールドを復号アクセサ経由で読み、同じ値を書き戻す＝setter が暗号化して平文カラムを空にする。
    /// - `contentHash` は素の SHA-256 から鍵付き HMAC（blind index）へ再計算する。全行を同時に
    ///   再計算するので、移行後も重複排除（bump-to-top）は正しく機能する。
    /// - フラグは**成功したときだけ**立てる（backfill/dedupe と同じ理由）。失敗時は次回起動で再試行。
    func encryptLegacyHistoryIfNeeded(storeURL: URL?) {
        let key = "tameo.history.encrypted.v1"
        guard !flagDefaults.bool(forKey: key) else { return }

        guard let all = try? modelContext.fetch(FetchDescriptor<ClipboardItem>()) else {
            NSLog("Tameo: 暗号化移行の fetch に失敗; 次回起動で再試行します")
            return
        }
        let legacy = all.filter(\.needsEncryptionMigration)
        let backupURL = storeURL?.deletingLastPathComponent()
            .appendingPathComponent("Tameo.store.pre-encryption-backup")

        if !legacy.isEmpty {
            // 1. 移行前バックアップ（同ディレクトリに固定名で1つ。再試行時は上書き＝常に「未移行状態」の控え）。
            if let storeURL, let backupURL {
                if let failure = StoreLocation.backupDatabase(from: storeURL, to: backupURL) {
                    NSLog("Tameo: 暗号化移行前のバックアップに失敗（移行は中止・次回起動で再試行）: %@", failure)
                    return
                }
            }

            // 2. 全フィールドを読み→書き戻し（setter が暗号化）。ハッシュは HMAC へ再計算。
            let sampleBefore = legacy.first?.content
            for item in legacy {
                item.content = item.content
                item.searchIndex = item.searchIndex
                item.ocrText = item.ocrText
                item.fileURLStrings = item.fileURLStrings
                item.colorHex = item.colorHex
                item.payloadData = item.payloadData
                item.thumbnailPNG = item.thumbnailPNG
                item.contentHash = HistoryVault.blindIndexHex(canonicalBytes(of: item))
            }
            guard save() else {
                NSLog("Tameo: 暗号化移行の保存に失敗; 次回起動で再試行します")
                return
            }
            // 3. 検証: 移行後も同じ内容が読めること（読めなければフラグを立てず、バックアップも残す）。
            if let sampleBefore, legacy.first?.content != sampleBefore {
                NSLog("Tameo: 暗号化移行の検証に失敗（内容不一致）。バックアップを残して次回起動で再試行します")
                return
            }
            NSLog("Tameo: 履歴 %d 件を暗号化しました", legacy.count)
        }

        // 4. 平文の残骸の物理削除（**行の暗号化だけでは不十分**）。UPDATE 前の古い行イメージは
        //    SQLite の空きページ・WAL に残り、ファイルの生バイトから平文が読める（strings で実証済み）。
        //    WAL チェックポイント＋VACUUM でファイルを作り直して残骸ごと消す。
        //    失敗したらフラグを立てず次回起動で再試行（そのとき legacy は空でもここへ到達する）。
        if let storeURL {
            if let failure = StoreLocation.compactStore(at: storeURL) {
                NSLog("Tameo: 暗号化移行後の VACUUM に失敗; 次回起動で再試行します: %@", failure)
                return
            }
            // 5. 検証済みなので平文の控え（バックアップ）は処分する。残すと「保存時暗号化」の意味が薄れる。
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
            }
        }
        flagDefaults.set(true, forKey: key)
    }

    /// 渡された一覧のうち検索インデックスが空の行を補完する（一覧表示の直前に使う遅延 backfill）。
    ///
    /// 起動時の `backfillSearchIndexIfNeeded` が本線だが、そちらが何らかの理由で取りこぼした行が
    /// あっても、目に触れた時点でここが拾う。`searchIndex` が空の行はどのクエリにもヒットしないため、
    /// 保険を二重にしておく（以前は 1 項目版が存在するだけで呼び出し元がなく、死んでいた）。
    func ensureSearchIndexes(in items: [ClipboardItem]) {
        var changed = false
        for item in items where item.searchIndex.isEmpty {
            item.searchIndex = item.searchableSourceText
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Private

    private func newestItem() -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    /// 履歴全体から、種別と内容ハッシュが一致する既存項目を1件だけ引く（bump-to-top の重複検出）。
    /// インデックス的にはハッシュ等価フィルタで DB 側に絞らせ、全件フェッチを避ける。
    private func existingItem(kindRaw: String, contentHash: String) -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.contentHash == contentHash },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func prune() {
        let maxHistory = settings.maxHistory
        // まず件数だけを問い合わせ、上限以下なら全件フェッチを避ける（O(n) 全スキャン回避）。
        let total = (try? modelContext.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0
        guard total > maxHistory else { return }
        let d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        guard let items = try? modelContext.fetch(d) else { return }
        // ピン留めは削除対象から除外し、上限は「ピン以外」に対して適用する。
        let unpinned = items.filter { !$0.isPinned }
        guard unpinned.count > maxHistory else { return }
        for item in unpinned[maxHistory...] {
            modelContext.delete(item)
        }
    }

    /// 保存する。成功したかを返す（一度きりの移行処理は、成功を確認してからフラグを立てるため）。
    @discardableResult
    private func save() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            // 通常の取り込み経路では保存失敗は致命ではないのでログのみ（将来は通知/リトライ）。
            NSLog("Tameo: history save failed: %@", String(describing: error))
            return false
        }
    }
}
