import XCTest
import SwiftData
@testable import Tameo

/// 層1: 履歴の保存時暗号化（常時オン）の検証。
/// - Vault の封/開/改ざん検出
/// - 新規取り込みが平文カラムを残さないこと（at-rest の実体検査）
/// - レガシ平文行の一度きり移行（読める・暗号化される・ハッシュがHMACへ揃う・フラグ運用）
@MainActor
final class HistoryEncryptionTests: XCTestCase {

    private var retainedContainers: [ModelContainer] = []

    override func tearDown() {
        retainedContainers.removeAll()
        super.tearDown()
    }

    private func makeStore() -> (store: HistoryStore, context: ModelContext, flags: UserDefaults) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: ClipboardItem.self, SnippetFolder.self, Snippet.self,
            configurations: config)
        retainedContainers.append(container)
        let context = container.mainContext
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tameo.test.\(UUID().uuidString)")!)
        let flags = UserDefaults(suiteName: "tameo.test.flags.\(UUID().uuidString)")!
        let store = HistoryStore(modelContext: context, settings: settings, flagDefaults: flags)
        return (store, context, flags)
    }

    private func allItems(_ context: ModelContext) -> [ClipboardItem] {
        (try? context.fetch(FetchDescriptor<ClipboardItem>())) ?? []
    }

    // MARK: - Vault

    func test_vault_roundtripAndTamperDetection() {
        let sealed = HistoryVault.sealString("秘密のテキスト🔑")!
        XCTAssertEqual(HistoryVault.openString(sealed), "秘密のテキスト🔑")
        XCTAssertNotEqual(sealed, Data("秘密のテキスト🔑".utf8), "封をした結果は平文ではない")

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(HistoryVault.open(tampered), "1バイト改ざんは AES-GCM の認証で弾かれる")
    }

    func test_vault_blindIndexIsKeyedAndStable() {
        let data = Data("https://example.com".utf8)
        XCTAssertEqual(HistoryVault.blindIndexHex(data), HistoryVault.blindIndexHex(data), "決定的")
        // 鍵付きなので素の SHA-256 とは一致しない（DB 持ち出しでの辞書照合を防ぐ核心）。
        let plainSHA = "100680ad546ce6a577f42f52df33b4cfdca756859e664b8d7de329b150d09ce9"
        XCTAssertNotEqual(HistoryVault.blindIndexHex(data), plainSHA)
    }

    // MARK: - 新規取り込みの at-rest 実体

    func test_ingest_leavesNoPlaintextInStoredColumns() {
        let (store, context, _) = makeStore()
        store.ingest(text: "口座番号 1234-567", sourceBundleID: nil, isConcealed: false)

        let item = allItems(context)[0]
        // 復号アクセサでは読める。
        XCTAssertEqual(item.content, "口座番号 1234-567")
        XCTAssertTrue(item.searchIndex.contains("1234-567"))
        // 保存カラム（ディスクに載る側）には平文がない。
        XCTAssertEqual(item.storedContent, "", "平文カラムは空")
        XCTAssertEqual(item.storedSearchIndex, "", "索引の平文カラムも空")
        XCTAssertNotNil(item.encContent)
        XCTAssertNotNil(item.encSearchIndex)
        // 暗号カラムに平文のバイト列が含まれない。
        XCTAssertNil(String(data: item.encContent!, encoding: .utf8)?.range(of: "口座番号"))
        XCTAssertFalse(item.needsEncryptionMigration)
    }

    func test_search_worksOverEncryptedIndex() {
        let (store, _, _) = makeStore()
        store.ingest(text: "ドコモ Ａｐｐｌｅ 請求", sourceBundleID: nil, isConcealed: false)
        store.ingest(text: "無関係", sourceBundleID: nil, isConcealed: false)
        // 暗号化後もメモリ内検索で正規化込みのヒットが得られる。
        let hits = store.searchHistory(query: "apple", kinds: [], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(hits.map(\.content), ["ドコモ Ａｐｐｌｅ 請求"])
    }

    func test_ingest_dedupStillBumpsWithBlindIndex() {
        let (store, context, _) = makeStore()
        store.ingest(text: "A", sourceBundleID: nil, isConcealed: false)
        store.ingest(text: "B", sourceBundleID: nil, isConcealed: false)
        store.ingest(text: "A", sourceBundleID: nil, isConcealed: false)
        XCTAssertEqual(allItems(context).count, 2, "HMAC化後も bump-to-top が効く")
    }

    // MARK: - レガシ移行

    /// 暗号化導入前の行をシミュレート: 平文カラムに直接値を置き、enc* を空にする。
    private func plantLegacyRow(_ context: ModelContext, content: String) -> ClipboardItem {
        let item = ClipboardItem(content: "placeholder")
        context.insert(item)
        item.encContent = nil
        item.encSearchIndex = nil
        item.encOcrText = nil
        item.storedContent = content
        item.storedSearchIndex = SearchNormalizer.indexString(content: content)
        item.contentHash = "deadbeef"   // 旧方式（素のSHA-256）の名残を模す
        item.invalidateDecryptedCaches()   // カラム直書きしたので復号キャッシュを捨てる（実運用に直書き経路はない）
        try? context.save()
        return item
    }

    func test_encryptLegacyHistory_migratesReadsAndRekeysHash() {
        let (store, context, flags) = makeStore()
        let legacy = plantLegacyRow(context, content: "移行前の平文")
        XCTAssertTrue(legacy.needsEncryptionMigration)

        store.encryptLegacyHistoryIfNeeded(storeURL: nil)   // インメモリなのでバックアップはスキップ

        XCTAssertFalse(legacy.needsEncryptionMigration)
        XCTAssertEqual(legacy.content, "移行前の平文", "移行後も読める")
        XCTAssertEqual(legacy.storedContent, "", "平文カラムは空になる")
        XCTAssertEqual(legacy.storedSearchIndex, "")
        XCTAssertNotEqual(legacy.contentHash, "deadbeef", "ハッシュはHMACへ再計算される")
        XCTAssertTrue(flags.bool(forKey: "tameo.history.encrypted.v1"), "成功したのでフラグが立つ")
    }

    func test_encryptLegacyHistory_dedupMatchesAcrossMigration() {
        let (store, context, _) = makeStore()
        _ = plantLegacyRow(context, content: "同じ内容")
        store.encryptLegacyHistoryIfNeeded(storeURL: nil)
        // 移行でHMACへ揃った後、同じ内容を再コピー → 新規行ではなく既存行の繰り上げになる。
        store.ingest(text: "同じ内容", sourceBundleID: nil, isConcealed: false)
        XCTAssertEqual(allItems(context).count, 1, "移行後の再コピーが重複行を作らない")
    }

    func test_encryptLegacyHistory_freshInstallJustSetsFlag() {
        let (store, context, flags) = makeStore()
        XCTAssertTrue(allItems(context).isEmpty)
        store.encryptLegacyHistoryIfNeeded(storeURL: nil)
        XCTAssertTrue(flags.bool(forKey: "tameo.history.encrypted.v1"))
    }

    func test_encryptLegacyHistory_secondRunIsNoop() {
        let (store, context, flags) = makeStore()
        _ = plantLegacyRow(context, content: "一度だけ")
        store.encryptLegacyHistoryIfNeeded(storeURL: nil)
        let hashAfterFirst = allItems(context)[0].contentHash
        // フラグ済みなら再実行は何もしない（ハッシュが再計算で変わったりしない）。
        store.encryptLegacyHistoryIfNeeded(storeURL: nil)
        XCTAssertEqual(allItems(context)[0].contentHash, hashAfterFirst)
        XCTAssertTrue(flags.bool(forKey: "tameo.history.encrypted.v1"))
    }
}
