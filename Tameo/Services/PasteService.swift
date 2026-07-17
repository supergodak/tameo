import AppKit
import CoreGraphics
import Observation
import Sauce

/// ペースト機構。
/// - `copyToClipboard`: 書き込みのみ（プライバシー上クリーン）。
/// - `paste`: ペーストボードへ書込 → 対象アプリを前面へ戻す → フォーカス復帰を確認して Cmd+V を合成送出。
/// 書き込み・CGEvent送出は内容読みではないため macOS 15.4/26 のペーストボード・プライバシー警告は出ない。
/// 貼り付け先アプリと、その貼り付け方式。
/// - `isNonActivating`=false: 通常アプリ。前面へ activate してからセッションタップへ Cmd+V（従来方式）。
/// - `isNonActivating`=true : Spotlight / Alfred / Toppoi 型の非活性パネル。activate すると引っ込む/
///   フォーカスが外れるため、前面化せず対象プロセスへ `CGEvent.postToPid` で直送する。
struct PasteDestination {
    let app: NSRunningApplication
    let isNonActivating: Bool
}

@MainActor
protocol PasteServicing {
    func copyToPasteboard(_ item: ClipboardItem)
    func copyAsPlainText(_ item: ClipboardItem)
    func paste(_ item: ClipboardItem, asPlainText: Bool, to target: PasteDestination?)
    /// スニペット等の生テキストを貼り付ける（履歴項目ではない経路）。
    func pasteText(_ text: String, to target: PasteDestination?)
}

@MainActor
@Observable
final class PasteService: PasteServicing {
    /// 自己コピー抑止ゲート（書き込み直後に changeCount を記録し、監視側の再取り込みを止める）。
    private let gate: PasteboardWriteGate
    private let settings: SettingsStore

    init(gate: PasteboardWriteGate, settings: SettingsStore) {
        self.gate = gate
        self.settings = settings
    }

    /// 選択項目を種別に応じて汎用ペーストボードへ書き込むだけ（合成ペーストはしない）。
    func copyToPasteboard(_ item: ClipboardItem) {
        _ = writeToPasteboard(item, asPlainText: false)
    }

    /// 選択項目をプレーンテキストとして書き込む（リッチ装飾を捨てる。Clipy の「プレーンで貼付」相当）。
    func copyAsPlainText(_ item: ClipboardItem) {
        _ = writeToPasteboard(item, asPlainText: true)
    }

    /// 選択項目を `target`（ホットキー発火時に AX で捕捉したフォーカス先）へ貼り付ける。
    func paste(_ item: ClipboardItem, asPlainText: Bool, to target: PasteDestination?) {
        // 1) ペーストボードへ書込（種別別）。未コミットなら合成キーを送らない。
        guard writeToPasteboard(item, asPlainText: asPlainText) else {
            NSLog("Tameo: pasteboard write did not commit; abort paste")
            return
        }
        // 2) 貼り付け対象が取れていない場合は合成キーを送らない（誤爆防止）。
        //    内容は既にペーストボードへ載っているので、ユーザーが手動で貼り付け可能。
        guard let target else { return }
        synthesizePasteCommand(to: target)
    }

    /// スニペット等の生テキストを貼り付ける（履歴項目ではない経路）。
    /// 書き込み後に gate へ changeCount を記録するため、監視は自己コピーをスキップし履歴を汚染しない。
    func pasteText(_ text: String, to target: PasteDestination?) {
        // 空テキストは何もしない。clearContents でユーザーの現在のクリップボードを消さないため
        //（本文が空のスニペットを選んでもクリップボードを破壊しない）。
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard pb.types?.isEmpty == false else { return }
        gate.noteSelfWrite(changeCount: pb.changeCount)
        guard let target else { return }
        synthesizePasteCommand(to: target)
    }

    /// ペーストボード書込済みの内容を `target` へ合成 Cmd+V で送る共通処理。
    private func synthesizePasteCommand(to target: PasteDestination) {
        // 「選択後に⌘Vを自動入力」が無効なら、内容はペーストボードへ載っているので手動貼付に委ねて終了。
        guard settings.inputPasteCommand else { return }
        // アクセシビリティ未許可なら合成キーは送れない。プロンプト後も未許可なら設定画面へ誘導。
        guard AccessibilityAuthorization.isTrusted else {
            AccessibilityAuthorization.requestPrompt()
            if !AccessibilityAuthorization.isTrusted {
                AccessibilityAuthorization.openSettingsPane()
            }
            return
        }
        // レイアウト補正済みの V キーコードを Sauce から取得（手動QWERTYゲートは書かない）。
        let vKey = Sauce.shared.keyCode(for: .v)

        if target.isNonActivating {
            // Spotlight / Alfred / Toppoi 型パネル: activate すると引っ込む/フォーカスが外れるため、
            // 前面化せず対象プロセスへ直接 Cmd+V を送る（セッションタップ＝最前面宛てでは届かない）。
            Self.postCommandV(virtualKey: vKey, toPid: target.app.processIdentifier)
            return
        }
        // 通常アプリ: 合成 Cmd+V は前面アプリへ届くため、対象を前面へ戻してから送出。
        target.app.activate()
        // フォーカスが対象へ実際に戻ってから送出（固定遅延より堅牢。最大 ~0.24s でタイムアウト送出）。
        Self.postCommandV(virtualKey: vKey, whenFrontmost: target.app, attemptsLeft: 8)
    }

    /// 種別別にペーストボードへ書き込む。書き込み後の changeCount を gate へ記録（自己コピー抑止）。
    /// 戻り値 = コミットされたか（changeCount が増えたか）。
    @discardableResult
    private func writeToPasteboard(_ item: ClipboardItem, asPlainText: Bool) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()

        if asPlainText {
            pb.setString(plainText(for: item), forType: .string)
        } else {
            switch item.kind {
            case .filename:
                // 既定はパス文字列（ターミナル/エディタ向け）。実ファイル参照も併載し Finder では複製可能に。
                let objects: [NSPasteboardWriting] = (item.fileURLs as [NSURL]) + [item.content as NSString]
                pb.writeObjects(objects)
            case .text, .url:
                pb.setString(item.content, forType: .string)
            case .color:
                // 色対応アプリには NSColor、プレーン先には #hex 文字列を併載。
                if let color = NSColor(hexString: item.colorHex) {
                    pb.writeObjects([color, item.content as NSString])
                } else {
                    pb.setString(item.content, forType: .string)
                }
            case .png, .tiff:
                // 画像はラベル文字列を .string に書かない（"Image · …" を貼るのは無より悪い）。
                // 原本があればそれを、truncated 等で無ければサムネ PNG を貼る。
                let imgType: NSPasteboard.PasteboardType = (item.kind == .png) ? .png : .tiff
                if let data = item.payloadData, !data.isEmpty {
                    pb.setData(data, forType: imgType)
                } else if let thumb = item.thumbnailPNG, !thumb.isEmpty {
                    pb.setData(thumb, forType: .png)
                }
            case .rtf:
                if let data = item.payloadData, !data.isEmpty {
                    pb.setData(data, forType: .rtf)
                }
                pb.setString(item.content, forType: .string)   // 平文フォールバック（content は平文化済み）
            case .rtfd:
                if let data = item.payloadData, !data.isEmpty {
                    pb.setData(data, forType: .rtfd)
                }
                pb.setString(item.content, forType: .string)
            case .pdf:
                // 原本があれば PDF データを貼る。ラベルは通常 .string に書かない（無意味なため）。
                if let data = item.payloadData, !data.isEmpty {
                    pb.setData(data, forType: .pdf)
                } else {
                    // 原本破棄(>8MB)時は最低限ラベルを貼る（clearContents 済みのクリップボードを空のまま放置しない）。
                    pb.setString(item.content, forType: .string)
                }
            }
        }

        // clearContents() 自体が changeCount を進めるため「増えたか」では実書込を判定できない。
        // 書き込まれた型の有無で実コミットを判定する（filename で URL/文字列とも空なら未コミット）。
        let committed = (pb.types?.isEmpty == false)
        if committed { gate.noteSelfWrite(changeCount: pb.changeCount) }
        return committed
    }

    /// プレーン貼付時の文字列。PR-A は content がそのまま平文
    /// （rtf 等の平文化は PR-C で content に格納済みのものを使う）。
    private func plainText(for item: ClipboardItem) -> String {
        item.content
    }

    /// 対象アプリが前面に戻るのを待ってから Cmd+V を送出する（タイムアウト時は対象 PID へ直送）。
    private static func postCommandV(virtualKey: CGKeyCode, whenFrontmost target: NSRunningApplication, attemptsLeft: Int) {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        if isFront {
            // 対象が前面に戻っても、テキスト入力欄のフォーカス復帰は一拍遅れることがある。
            // 特にブラウザの web テキスト領域（DOM フォーカス）は復帰が遅く、早すぎる Cmd+V を
            // 取りこぼす（＝何も貼られない）。ネイティブアプリは即復帰なので体感差はほぼ無い。
            // 前面確認後に短い settle を1回だけ入れてから送出する。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // settle 中にユーザーが別ウィンドウへ移った場合は誤爆になるため送出を中止する。
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == target.processIdentifier else { return }
                postCommandV(virtualKey: virtualKey)
            }
            return
        }
        if attemptsLeft <= 0 {
            // タイムアウト（~0.24s）: 対象が前面に戻らなかった。
            // ここでセッションタップへ盲目送出すると、その瞬間に前面だった**別のアプリ**へ
            // クリップボードの内容（パスワード等を含み得る）が貼られる。ユーザーが選んでいない
            // 宛先へ機密を流すため、この経路は取らない。
            // 一方で「前面判定が効かないアプリでも貼れる」というフォールバックの目的は維持したいので、
            // 宛先を対象プロセスに限定した直送へ切り替える。対象が居なければ何も起きないだけで、
            // 第三者アプリへ届くことは原理的にない。
            guard !target.isTerminated else { return }
            postCommandV(virtualKey: virtualKey, toPid: target.processIdentifier)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            postCommandV(virtualKey: virtualKey, whenFrontmost: target, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Cmd+V を合成してセッション・イベントタップへ送出（＝最前面アプリ宛て。通常アプリ用）。
    private static func postCommandV(virtualKey: CGKeyCode) {
        guard let (keyDown, keyUp) = makeCommandVEvents(virtualKey: virtualKey) else { return }
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    /// Cmd+V を合成して特定プロセスへ直送（非活性パネル用。前面化不要で届く）。
    private static func postCommandV(virtualKey: CGKeyCode, toPid pid: pid_t) {
        guard let (keyDown, keyUp) = makeCommandVEvents(virtualKey: virtualKey) else { return }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    /// Cmd 修飾付きの V キーダウン/アップ CGEvent 対を生成する（送出先は呼び出し側が選ぶ）。
    private static func makeCommandVEvents(virtualKey: CGKeyCode) -> (CGEvent, CGEvent)? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return (keyDown, keyUp)
    }
}
