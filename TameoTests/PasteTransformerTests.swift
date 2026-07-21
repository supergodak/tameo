import XCTest
@testable import Tameo

/// 層1: 貼付変換（⌃番号）の純関数検証。履歴データに触れないことは設計上自明（apply は String→String）。
@MainActor
final class PasteTransformerTests: XCTestCase {

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "tameo.test.\(UUID().uuidString)")!)
    }

    // MARK: - 全角→半角

    func test_toHalfWidth_convertsAlnumAndSymbols() {
        XCTAssertEqual(PasteTransformer.toHalfWidth("ＡＢＣ　ｘｙｚ　１２３％（）"), "ABC xyz 123%()")
    }

    func test_toHalfWidth_leavesKanaAndKanjiAlone() {
        // かな・漢字・半角カナは対象外（NFKC を使わない理由そのもの）。全角空白だけ半角になる。
        XCTAssertEqual(PasteTransformer.toHalfWidth("カタカナ　ひらがな　漢字　ｶﾅ"), "カタカナ ひらがな 漢字 ｶﾅ")
    }

    // MARK: - URLクリーン

    func test_cleanURL_stripsTrackingKeepsRealParams() {
        XCTAssertEqual(
            PasteTransformer.cleanURL("https://example.com/page?utm_source=x&id=42&fbclid=abc"),
            "https://example.com/page?id=42")
    }

    func test_cleanURL_removesQuestionMarkWhenAllTracking() {
        XCTAssertEqual(
            PasteTransformer.cleanURL("https://example.com/page?utm_source=x&utm_medium=mail"),
            "https://example.com/page")
    }

    func test_cleanURL_preservesFragment() {
        XCTAssertEqual(
            PasteTransformer.cleanURL("https://example.com/a?utm_source=x#section"),
            "https://example.com/a#section")
    }

    func test_cleanURL_leavesNonSingleURLTextAlone() {
        // URLが文中に混ざるだけのテキスト・URLでないテキストは触らない（削りすぎ防止）。
        let prose = "リンクは https://example.com/a?utm_source=x を見てください"
        XCTAssertEqual(PasteTransformer.cleanURL(prose), prose)
        XCTAssertEqual(PasteTransformer.cleanURL("utm_source とは何か"), "utm_source とは何か")
        XCTAssertEqual(PasteTransformer.cleanURL("https://example.com/plain"), "https://example.com/plain")
    }

    // MARK: - 空白整理

    func test_tidyWhitespace_trimsJoinsAndCollapses() {
        XCTAssertEqual(PasteTransformer.tidyWhitespace("  改行が\n混ざった\t コピー  "), "改行が 混ざった コピー")
    }

    // MARK: - apply（設定連動と適用順）

    func test_apply_respectsSettingsFlags() {
        let s = makeSettings()   // 既定: 半角化=on, URL=on, 空白=off
        XCTAssertEqual(PasteTransformer.apply("Ｘ１\n２", settings: s), "X1\n2", "空白整理offなら改行は残る")
        s.transformTidyWhitespace = true
        XCTAssertEqual(PasteTransformer.apply("Ｘ１\n２", settings: s), "X1 2")
        s.transformHalfWidth = false
        s.transformTidyWhitespace = false
        XCTAssertEqual(PasteTransformer.apply("Ｘ１", settings: s), "Ｘ１", "半角化offなら全角のまま")
    }

    func test_apply_cleansURLWithoutHalfWidthCorruptingIt() {
        // 既定（半角化on・URLクリーンon）で、通常のURLはクリーンされ、半角化がURLを壊さない。
        // ※全角文字入りクエリは URLComponents が正しくパーセントエンコードするため、
        //   「URL内の全角も半角化される」ことは仕様として保証しない（実URLでは起きない合成ケース）。
        let s = makeSettings()
        XCTAssertEqual(
            PasteTransformer.apply("https://example.com/p?gclid=1&q=1", settings: s),
            "https://example.com/p?q=1")
    }
}
