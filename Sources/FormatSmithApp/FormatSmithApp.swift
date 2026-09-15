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

    var body: some Scene {
        // 单窗口工具：用 Window 而不是 WindowGroup，
        // 否则「用 FormatSmith 打开」多个文件时每个文件都会弹一个新窗口。
        Window("FormatSmith", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(Localized.text("Choose Files…")) { model.chooseInputFiles() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button(Localized.text("Clear List")) { model.removeAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.items.isEmpty || model.isConverting)
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
        DebugLog.log("收到打开文件事件: \(urls.map(\.lastPathComponent))")
        guard let model else {
            DebugLog.log("model 尚未就绪，丢弃本次打开事件")
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
