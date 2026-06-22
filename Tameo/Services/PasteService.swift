import AppKit
import CoreGraphics
import Observation
import Sauce

/// ペースト機構。
/// - `copyToClipboard`: 書き込みのみ（プライバシー上クリーン）。
/// - `paste`: ペーストボードへ書込 → 対象アプリを前面へ戻す → フォーカス復帰を確認して Cmd+V を合成送出。
/// 書き込み・CGEvent送出は内容読みではないため macOS 15.4/26 のペーストボード・プライバシー警告は出ない。
@MainActor
protocol PasteServicing {
    func copyToClipboard(_ text: String)
    func paste(_ text: String, to target: NSRunningApplication?)
}

@MainActor
@Observable
final class PasteService: PasteServicing {
    /// 選択テキストを汎用ペーストボードへ書き込むだけ（合成ペーストはしない）。
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 選択テキストを `target`（ホットキー発火時に捕捉した前面アプリ）へ貼り付ける。
    func paste(_ text: String, to target: NSRunningApplication?) {
        guard !text.isEmpty else { return }

        // 1) ペーストボードへ書込。changeCount の増加で反映を確認（整数読みなので警告は出ない）。
        let pb = NSPasteboard.general
        let before = pb.changeCount
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard pb.changeCount != before else {
            NSLog("Tameo: pasteboard write did not commit; abort paste")
            return
        }

        // 2) 貼り付け対象が取れていない場合は合成キーを送らない（誤爆防止）。
        //    テキストは既にペーストボードへ載っているので、ユーザーが手動で貼り付け可能。
        guard let target else { return }

        // 3) アクセシビリティ未許可なら合成キーは送れない。プロンプト後も未許可なら設定画面へ誘導。
        guard AccessibilityAuthorization.isTrusted else {
            AccessibilityAuthorization.requestPrompt()
            if !AccessibilityAuthorization.isTrusted {
                AccessibilityAuthorization.openSettingsPane()
            }
            return
        }

        // 4) 合成 Cmd+V は前面アプリへ届くため、対象アプリを前面へ戻す。
        target.activate()

        // 5) レイアウト補正済みの V キーコードを Sauce から取得（手動QWERTYゲートは書かない）。
        let vKey = Sauce.shared.keyCode(for: .v)

        // フォーカスが対象へ実際に戻ってから送出（固定遅延より堅牢。最大 ~0.24s でタイムアウト送出）。
        Self.postCommandV(virtualKey: vKey, whenFrontmost: target, attemptsLeft: 8)
    }

    /// 対象アプリが前面に戻るのを待ってから Cmd+V を送出する（タイムアウトで強制送出）。
    private static func postCommandV(virtualKey: CGKeyCode, whenFrontmost target: NSRunningApplication, attemptsLeft: Int) {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        if isFront || attemptsLeft <= 0 {
            postCommandV(virtualKey: virtualKey)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            postCommandV(virtualKey: virtualKey, whenFrontmost: target, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Cmd+V を合成してセッション・イベントタップへ送出。
    private static func postCommandV(virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
