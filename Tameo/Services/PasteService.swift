import AppKit
import Observation

/// ペースト機構の口。M1は書き込み側（クリップボードへコピー）だけ実装。
/// 実際の前面アプリへの貼り付け（CGEventで Cmd+V 合成 + Sauce + アクセシビリティ）はM2。
@MainActor
protocol PasteServicing {
    func copyToClipboard(_ text: String)
}

@MainActor
@Observable
final class PasteService: PasteServicing {
    /// 選択テキストを汎用ペーストボードへ書き込む（プライバシー上クリーンな書き込み操作）。
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // M2: func paste(_ text: String, into app: NSRunningApplication?)
    //     -> NSPasteboard 書き込み + Sauce.shared.keyCode(for: .v) + CGEvent(.cgSessionEventTap) + アクセシビリティ確認
}
