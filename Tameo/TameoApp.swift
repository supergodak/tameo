import SwiftUI
import SwiftData

/// Tameo のエントリポイント。
/// メニューバー常駐（`MenuBarExtra`）+ SwiftData による履歴永続化の骨組み。
/// 実際のクリップボード監視・ホットキー・ペーストはフェーズ1で実装する。
@main
struct TameoApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: ClipboardItem.self)
        } catch {
            fatalError("ModelContainer の生成に失敗: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("Tameo", systemImage: "doc.on.clipboard") {
            MenuBarContentView()
                .modelContainer(modelContainer)
        }
        .menuBarExtraStyle(.window)
    }
}
