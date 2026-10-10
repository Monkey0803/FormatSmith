import AppKit
import FormatSmithCore
import SwiftUI

@main
struct FormatSmithApp: App {
    @StateObject private var model = ConverterModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 命令行模式下不打开窗口（脚本调用 / 自动化）。
        CommandLineTool.runIfNeeded()
    }

    /// 前九个预设对应 ⌘1…⌘9，第十个对应 ⌘0（十个预设刚好用满一行数字键）。
    private static func shortcutKey(for index: Int) -> KeyEquivalent {
        guard let digit = "1234567890".dropFirst(index).first else { return "0" }
        return KeyEquivalent(digit)
    }

    var body: some Scene {
        // 单窗口工具：用 Window 而不是 WindowGroup，
        // 否则「用 FormatSmith 打开」多个文件时每个文件都会弹一个新窗口。
        Window("FormatSmith", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear { appDelegate.model = model }
                // 语言变化时让视图重新取词（不重建视图树，滚动位置与输入焦点都会保留）。
                .localizedText(model.language)
                .sheet(isPresented: $model.showsShortcuts) { ShortcutsView() }
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            // 用自己的「关于」：版本、仓库地址、以及「文件不出这台机器」这件事
            CommandGroup(replacing: .appInfo) {
                Button(Localized.text("About FormatSmith")) { model.showsAbout = true }
            }
            CommandGroup(replacing: .newItem) {
                Button(Localized.text("Choose Files…")) { model.chooseInputFiles() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button(Localized.text("Clear List")) { model.removeAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.items.isEmpty || model.isConverting)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(Localized.text("Select All")) { model.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(model.items.isEmpty)
                Button(Localized.text("Deselect All")) { model.selection.removeAll() }
                    .disabled(model.selection.isEmpty)
                Button(Localized.text("Remove Selected")) { model.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selection.isEmpty || model.isConverting)
                Button(Localized.text("Copy File Names")) { model.copySelectedNames() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
            }

            CommandGroup(replacing: .help) {
                Button(Localized.text("Keyboard Shortcuts")) { model.showsShortcuts = true }
                Link(
                    Localized.text("Usage guide"),
                    destination: URL(string: "https://github.com/Monkey0803/FormatSmith#readme")!
                )
            }

            // ⌘1…⌘9、⌘0 套用十个预设
            CommandMenu(Localized.text("Presets")) {
                ForEach(Array(PresetLibrary.all.enumerated()), id: \.element.id) { index, preset in
                    Button(preset.name) { model.apply(preset) }
                        .keyboardShortcut(Self.shortcutKey(for: index), modifiers: .command)
                        .disabled(model.items.isEmpty || model.isConverting)
                }
            }

            CommandMenu(Localized.text("Language")) {
                // 读一次 language：切换后菜单标题也跟着更新
                let active = model.language
                ForEach(AppLanguage.allCases) { candidate in
                    Button {
                        model.language = candidate
                    } label: {
                        Text(candidate == active ? "✓ \(candidate.displayName)" : candidate.displayName)
                    }
                }
            }
            CommandMenu(Localized.text("Convert")) {
                Button(Localized.text("Convert Now")) { model.startConversion() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.items.isEmpty || model.isConverting)
                Button(Localized.text("Cancel")) { model.cancelConversion() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isConverting)
                Divider()
                Button(Localized.text("Open Output Folder")) { model.openOutputFolder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// 处理「用 FormatSmith 打开」以及从访达拖到 Dock 图标的事件。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ConverterModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.log("open-document event: \(urls.map(\.lastPathComponent))")
        guard let model else {
            DebugLog.log("model not ready yet; dropping the open-document event")
            return
        }
        Task { @MainActor in
            model.add(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
