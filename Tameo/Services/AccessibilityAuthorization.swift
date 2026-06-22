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
