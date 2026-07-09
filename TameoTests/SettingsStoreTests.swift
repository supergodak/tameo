import XCTest
@testable import Tameo

/// 層1: 設定の永続化と派生の検証。隔離した `UserDefaults(suiteName:)` を注入し、実ユーザー設定を汚さない。
@MainActor
final class SettingsStoreTests: XCTestCase {

    /// テストごとに独立した UserDefaults（他テスト・実環境と干渉しない）。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tameo.test.\(UUID().uuidString)")!
    }

    func test_defaults_areOnAndSane() {
        let s = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(s.maxHistory, 200)
        XCTAssertEqual(s.sortOrder, .lastUsed)
        XCTAssertTrue(s.inputPasteCommand)
        XCTAssertTrue(s.storeText)
        XCTAssertTrue(s.storeRichText)
        XCTAssertTrue(s.ignoreConcealed)
        XCTAssertTrue(s.ocrEnabled)
        XCTAssertTrue(s.excludedBundleIDs.isEmpty)
    }

    func test_scalarSettings_persistAcrossInstances() {
        let d = makeDefaults()
        do {
            let s = SettingsStore(defaults: d)
            s.maxHistory = 42
            s.sortOrder = .createdAt
            s.inputPasteCommand = false
            s.ocrEnabled = false
            s.ignoreConcealed = false
            s.excludedBundleIDs = ["com.apple.Safari", "com.1password"]
        }
        // 同じ UserDefaults から作り直しても値が残っている＝didSet 永続化が効いている。
        let reloaded = SettingsStore(defaults: d)
        XCTAssertEqual(reloaded.maxHistory, 42)
        XCTAssertEqual(reloaded.sortOrder, .createdAt)
        XCTAssertFalse(reloaded.inputPasteCommand)
        XCTAssertFalse(reloaded.ocrEnabled)
        XCTAssertFalse(reloaded.ignoreConcealed)
        XCTAssertEqual(reloaded.excludedBundleIDs, ["com.apple.Safari", "com.1password"])
    }

    func test_isStoreEnabled_reflectsPerTypeToggles() {
        let s = SettingsStore(defaults: makeDefaults())
        // 既定は全種別 true。
        for kind in ClipKind.allCases { XCTAssertTrue(s.isStoreEnabled(kind)) }

        s.storeText = false
        XCTAssertFalse(s.isStoreEnabled(.text))

        s.storeRichText = false
        XCTAssertFalse(s.isStoreEnabled(.rtf))
        XCTAssertFalse(s.isStoreEnabled(.rtfd))

        s.storePDF = false
        XCTAssertFalse(s.isStoreEnabled(.pdf))

        s.storeImage = false
        XCTAssertFalse(s.isStoreEnabled(.png))
        XCTAssertFalse(s.isStoreEnabled(.tiff))

        // 触っていない種別は true のまま。
        XCTAssertTrue(s.isStoreEnabled(.url))
        XCTAssertTrue(s.isStoreEnabled(.color))
        XCTAssertTrue(s.isStoreEnabled(.filename))
    }
}
