import XCTest
@testable import Tameo

/// 層1: Clipy スニペット XML インポータの取り込み上限とパースの検証。
/// 上限は「ユーザーが選んだ巨大／細工ファイルでメモリを食い潰さない・固まらない」ためのもの。
final class ClipySnippetImporterTests: XCTestCase {

    private func xml(_ body: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><folders>\(body)</folders>".utf8)
    }

    private func folder(title: String, snippets: String) -> String {
        "<folder enable=\"true\"><title>\(title)</title><snippets>\(snippets)</snippets></folder>"
    }

    private func snippet(title: String, content: String) -> String {
        "<snippet enable=\"true\"><title>\(title)</title><content>\(content)</content></snippet>"
    }

    // MARK: - 正常系（上限を入れても従来どおり読めること）

    func test_parse_readsFoldersAndSnippets() throws {
        let data = xml(folder(title: "F1", snippets: snippet(title: "S1", content: "hello")))
        let folders = try ClipySnippetImporter.parse(data: data)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].title, "F1")
        XCTAssertEqual(folders[0].snippets.count, 1)
        XCTAssertEqual(folders[0].snippets[0].title, "S1")
        XCTAssertEqual(folders[0].snippets[0].content, "hello")
    }

    func test_parse_emptyDocument_throwsEmpty() {
        XCTAssertThrowsError(try ClipySnippetImporter.parse(data: xml(""))) { error in
            guard case ClipySnippetImporter.ImportError.empty = error else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    // MARK: - 上限（監査 #10）

    func test_parse_oversizedFile_isRejectedBeforeParsing() {
        // 上限を超えるバイト列は、XML として妥当かどうかに関係なく弾く。
        let big = Data(count: ClipySnippetImporter.maxFileBytes + 1)
        XCTAssertThrowsError(try ClipySnippetImporter.parse(data: big)) { error in
            guard case ClipySnippetImporter.ImportError.tooLarge = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
        }
    }

    func test_parse_oversizedContent_abortsWithTooLarge() {
        // 単一の <content> が上限超え。以前は buffer が無制限に伸びて食い潰せた。
        let huge = String(repeating: "a", count: ClipySnippetImporter.maxTextBytes + 1024)
        let data = xml(folder(title: "F", snippets: snippet(title: "S", content: huge)))
        XCTAssertThrowsError(try ClipySnippetImporter.parse(data: data)) { error in
            guard case ClipySnippetImporter.ImportError.tooLarge = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
        }
    }

    func test_parse_tooManyFolders_abortsWithTooLarge() {
        let body = String(repeating: folder(title: "F", snippets: ""),
                          count: ClipySnippetImporter.maxFolders + 1)
        XCTAssertThrowsError(try ClipySnippetImporter.parse(data: xml(body))) { error in
            guard case ClipySnippetImporter.ImportError.tooLarge = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
        }
    }

    /// 上限超過は「XML の構文エラー」ではなく上限として報告されること
    /// （ユーザーに出るメッセージが原因を取り違えないため）。
    func test_parse_overflowIsReportedAsTooLarge_notParseFailure() {
        let huge = String(repeating: "b", count: ClipySnippetImporter.maxTextBytes + 1)
        let data = xml(folder(title: "F", snippets: snippet(title: "S", content: huge)))
        XCTAssertThrowsError(try ClipySnippetImporter.parse(data: data)) { error in
            if case ClipySnippetImporter.ImportError.parseFailed = error {
                XCTFail("上限超過が構文エラーとして報告されている")
            }
        }
    }

    // MARK: - XXE（外部エンティティを解決しないこと）

    func test_parse_doesNotResolveExternalEntities() {
        // 外部エンティティを参照する XML。解決してしまうとローカルファイルを読み出せる。
        let evil = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE folders [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <folders><folder><title>F</title><snippets>
        <snippet><title>S</title><content>&xxe;</content></snippet>
        </snippets></folder></folders>
        """.utf8)
        // 解決されなければ、本文は空か素通し。いずれにせよ /etc/passwd の中身が混入しないこと。
        let folders = try? ClipySnippetImporter.parse(data: evil)
        let content = folders?.first?.snippets.first?.content ?? ""
        XCTAssertFalse(content.contains("root:"), "外部エンティティが解決されてはならない")
    }
}
