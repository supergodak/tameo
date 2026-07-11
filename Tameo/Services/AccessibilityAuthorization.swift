import AppKit
import ApplicationServices

/// アクセシビリティ権限（合成ペーストに必須）の確認・誘導。
/// M1ではCGEvent送出をしないため未行使だが、M2/初回導線の配線形を確定しておく。
/// 注: この権限はアプリの**コード署名身元に紐づく**。ad-hoc署名は再ビルド毎に身元が変わり許可が外れるため、
///     開発中からATIのDeveloper IDで署名するのが望ましい（チームID確定後に project.yml へ）。
enum AccessibilityAuthorization {
    /// 現在このプロセスが信頼済み（許可済み）か。
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 未許可ならシステムの許可プロンプトを出す（実際の表示頻度はOSが抑制する）。
    @discardableResult
    static func requestPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定のアクセシビリティ画面を開く。
    static func openSettingsPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// フォーカス解決: 「キーボードフォーカスを実際に持つアプリ」を Accessibility API で取得する。
///
/// non-activating panel（Spotlight / Alfred / Toppoi 型）は、入力欄にカーソルがあっても
/// アプリを活性化しないため `NSWorkspace.frontmostApplication` には現れない（背後のアクティブ
/// アプリや、開いた直後の Tameo 自身が返ってしまう）。貼り付け先を正しく特定するには、活性化状態
/// ではなく **キーボードフォーカス** を追う AX の `kAXFocusedApplicationAttribute` を使う。
/// 実測により、Toppoi のような非活性パネルでも AX は当該パネルのプロセスを正しく返すことを確認済み。
enum FocusResolver {
    /// システムワイドの `kAXFocusedApplicationAttribute` が指すアプリの PID。
    /// 権限が無い / 解決不能なら nil。
    static func focusedApplicationPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value else { return nil }
        // AX 属性値はアプリを表す AXUIElement（CFType）。所有プロセス PID を取り出す。
        let appElement = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// フォーカス中アプリを `NSRunningApplication` として返す。
    static func focusedApplication() -> NSRunningApplication? {
        guard let pid = focusedApplicationPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
