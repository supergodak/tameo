import SwiftUI

/// 一般設定タブ。グループ化フォーム（macOS System Settings 風の角丸カード＋説明 footer）。
struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .accessibilityIdentifier("toggle.launchAtLogin")
                Toggle("Press ⌘V automatically after selecting", isOn: $settings.inputPasteCommand)
                    .accessibilityIdentifier("toggle.autoPaste")
            } header: {
                Text("Startup & Paste")
            } footer: {
                Text("When automatic ⌘V is off, the selected item is only copied to the clipboard — paste it yourself with ⌘V.")
            }

            Section {
                Stepper(value: $settings.maxHistory, in: 10...1000, step: 10) {
                    LabeledContent("Items to keep", value: "\(settings.maxHistory)")
                }
                Picker("Sort order", selection: $settings.sortOrder) {
                    Text("Last used").tag(HistorySortOrder.lastUsed)
                    Text("Date created").tag(HistorySortOrder.createdAt)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Older items beyond this count are removed automatically. Sort order controls how the palette lists history.")
            }

            Section {
                Toggle("Full-width letters & digits → half-width", isOn: $settings.transformHalfWidth)
                    .accessibilityIdentifier("toggle.transformHalfWidth")
                Toggle("Strip URL tracking parameters (utm_*, fbclid, …)", isOn: $settings.transformCleanURL)
                    .accessibilityIdentifier("toggle.transformCleanURL")
                Toggle("Tidy whitespace (trim, join lines)", isOn: $settings.transformTidyWhitespace)
                    .accessibilityIdentifier("toggle.transformTidyWhitespace")
            } header: {
                Text("Paste Transform (⌃+number in the palette)")
            } footer: {
                Text("Hold ⌃ while picking an item to paste it as plain text with the checked transforms applied. Your history is never modified — only the pasted copy.")
            }
        }
        .formStyle(.grouped)
    }
}
