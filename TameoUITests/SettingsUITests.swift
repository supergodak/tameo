import XCTest

/// 層2: 設定ウィンドウを実際に起動して操作するUI駆動テスト。
/// `--uitest` で副作用（監視/ホットキー/Sparkle）を止め、`--uitest-open-settings` で設定画面を
/// 通常ウィンドウ（AppDelegate が NSHostingController で提示）として開く。
/// 設定トグルは SwiftUI の `Toggle` ＝ AX 上は `Switch`。タブは `Tab`（識別子＝SFシンボル名）。
final class SettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // 次テストへ状態が漏れない/前インスタンスが残らないよう、毎回確実に終了する（フレーク対策）。
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// Switch の値は環境により String "0"/"1" だったり数値だったりするため、型に依存せず文字列化して比較する。
    private func value(of element: XCUIElement) -> String { String(describing: element.value) }

    /// 存在＋操作可能になるまで待つ（waitForExistence は存在だけで、hittable でない瞬間のクリック取りこぼしを防ぐ）。
    @discardableResult
    private func waitHittable(_ element: XCUIElement, _ timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            usleep(80_000)
        }
        return element.exists && element.isHittable
    }

    private func launchWithSettings() -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments += ["--uitest", "--uitest-open-settings"]
        app.launch()
        app.activate()
        let window = app.windows["Tameo Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "設定ウィンドウが開いていない")
        return window
    }

    /// 設定ウィンドウが開き、GeneralタブのトグルがIDで見つかる。
    func test_settingsWindow_opensWithGeneralControls() {
        let window = launchWithSettings()
        XCTAssertTrue(window.switches["toggle.autoPaste"].waitForExistence(timeout: 8))
        XCTAssertTrue(window.switches["toggle.launchAtLogin"].exists)
    }

    /// Generalタブの「自動⌘V」トグルがクリックで反転する（UI操作→状態変化）。
    func test_general_autoPasteToggle_flips() {
        let window = launchWithSettings()
        let toggle = window.switches["toggle.autoPaste"]
        XCTAssertTrue(waitHittable(toggle), "自動⌘Vトグルが操作可能にならない")

        let before = value(of: toggle)
        toggle.click()
        XCTAssertNotEqual(before, value(of: toggle), "クリックでトグルの状態が反転するはず")
    }

    /// Typesタブへ切り替えられ、「Plain text」トグルが操作できる（タブ遷移込みのUI駆動）。
    func test_types_tab_isNavigableAndToggles() {
        let window = launchWithSettings()
        XCTAssertTrue(window.switches["toggle.autoPaste"].waitForExistence(timeout: 8))

        // Types タブ（識別子＝SFシンボル "square.on.square"）へ切り替え。
        let typesTab = app.descendants(matching: .any)["square.on.square"].firstMatch
        XCTAssertTrue(waitHittable(typesTab), "Types タブが操作可能にならない")
        typesTab.click()

        let storeText = window.switches["toggle.storeText"]
        XCTAssertTrue(waitHittable(storeText), "Types タブの Plain text トグルが操作可能にならない")
        let before = value(of: storeText)
        storeText.click()
        XCTAssertNotEqual(before, value(of: storeText), "Plain text トグルが反転するはず")
    }
}
