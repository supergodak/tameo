import SwiftUI

/// データ種別タブ。どの種別を履歴に保存するか＋機密データの扱い。
/// 既定はすべて保存・機密は無視＝従来等価。トグルは `ClipboardMonitor` が取り込み前に参照する。
struct TypesSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    /// 7 種別がすべてオフ＝何も履歴に追加されない状態。
    private var allTypesOff: Bool {
        !(settings.storeText || settings.storeRichText || settings.storePDF
          || settings.storeImage || settings.storeFilename || settings.storeURL || settings.storeColor)
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Plain text", isOn: $settings.storeText)
                Toggle("Rich text (RTF / RTFD)", isOn: $settings.storeRichText)
                Toggle("PDF", isOn: $settings.storePDF)
                Toggle("Images (PNG / TIFF)", isOn: $settings.storeImage)
                Toggle("File paths", isOn: $settings.storeFilename)
                Toggle("URLs", isOn: $settings.storeURL)
                Toggle("Colors", isOn: $settings.storeColor)
            } header: {
                Text("Save to history")
            } footer: {
                if allTypesOff {
                    Label("All types are off — nothing new will be added to history.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Turn off a type to stop adding it to history. Existing items are not removed.")
                }
            }

            Section {
                Toggle("Recognize text in images (OCR)", isOn: $settings.ocrEnabled)
            } header: {
                Text("Text recognition")
            } footer: {
                if settings.ocrEnabled {
                    Text("Copied images are scanned on-device (Apple Vision) so you can search them by their text and paste the recognized text with ⌥. Nothing leaves your Mac.")
                } else {
                    Text("Images won't be scanned. You can still store and paste them, but not search by their contents.")
                }
            }

            Section {
                Toggle("Skip password-manager items", isOn: $settings.ignoreConcealed)
            } header: {
                Text("Privacy")
            } footer: {
                if settings.ignoreConcealed {
                    Text("Items flagged as concealed (org.nspasteboard.ConcealedType) by password managers are never saved. Temporary and auto-generated items are always skipped regardless of this setting.")
                } else {
                    Label("Copied passwords and other concealed items will be saved to your local history.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
