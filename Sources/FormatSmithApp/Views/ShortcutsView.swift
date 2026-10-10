import FormatSmithCore
import SwiftUI

/// 快捷键一览。
///
/// 快捷键写在这个面板里，用户不必去翻文档才知道有这么回事。
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [(String, String)] = [
        ("⌘O", "Choose Files…"),
        ("⌘⏎", "Convert Now"),
        ("⌘.", "Cancel"),
        ("⌘⇧R", "Open Output Folder"),
        ("⌘⇧K", "Clear List"),
        ("⌘A", "Select All"),
        ("⌘Z", "Undo Remove"),
        ("⌫", "Remove Selected"),
        ("⌘⇧C", "Copy File Names"),
        ("⌘1 … ⌘0", "Apply a preset"),
        ("⌘W", "Close Window"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Localized.text("Keyboard shortcuts"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries, id: \.0) { key, label in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: key)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 84, alignment: .leading)
                        Text(Localized.text(label))
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack {
                Spacer()
                Button(Localized.text("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
