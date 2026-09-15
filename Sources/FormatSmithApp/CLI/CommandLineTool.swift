import AppKit
import FormatSmithCore
import Foundation

/// 命令行模式：同一个二进制既能开窗口，也能被脚本调用。
///
///     formatsmith --convert a.pdf b.pdf --format jpeg --dpi 150 --out ~/Desktop/out
///
/// 约定：数据走 stdout、诊断走 stderr；退出码 0 成功 / 1 部分失败 / 2 参数错误。
enum CommandLineTool {

    static func runIfNeeded() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let wantsCLI =
            arguments.contains("--convert")
            || arguments.contains("--help") || arguments.contains("-h")
            || arguments.contains("--list-formats")
            || arguments.contains("--check-dependencies")
            || arguments.contains("--version")
        guard wantsCLI else { return }

        exit(run(arguments: arguments))
    }

    // MARK: - 解析与执行

    private static func run(arguments: [String]) -> Int32 {
        var inputs: [String] = []
        var settings = ConversionSettings()
        settings.outputDirectoryPath = FileManager.default.currentDirectoryPath

        var index = 0
        func nextValue(_ flag: String) -> String? {
            guard index + 1 < arguments.count else {
                fail("Missing value for \(flag)")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--convert":
                while index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    index += 1
                    inputs.append(arguments[index])
                }

            case "--format", "--to":
                if let value = nextValue(argument) {
                    let key = value.lowercased()
                    guard
                        let format = allFormats.first(where: {
                            $0.identifier == key || $0.fileExtension == key || $0.displayName.lowercased() == key
                        })
                    else {
                        fail("Unknown format: \(value). Try --list-formats.")
                    }
                    settings.format = format
                }

            case "--quality":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.quality = min(max(number, 0.05), 1)
                }

            case "--dpi":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.resolutionMode = .dpi
                    settings.dpi = number
                }

            case "--scale":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.resolutionMode = .scale
                    settings.scale = number
                }

            case "--pages":
                if let value = nextValue(argument) {
                    settings.pageRangeMode = .custom
                    settings.pageRangeText = value
                }

            case "--out":
                if let value = nextValue(argument) {
                    settings.outputDirectoryPath = (value as NSString).expandingTildeInPath
                }

            case "--pattern":
                if let value = nextValue(argument) { settings.filenamePattern = value }

            case "--background":
                if let value = nextValue(argument), let style = ImageBackground(rawValue: value.lowercased()) {
                    settings.background = style
                }

            case "--no-subfolder":
                settings.perFileSubfolder = false

            case "--list-formats":
                printFormats(includeAll: true)
                return 0

            case "--check-dependencies":
                printDependencies()
                return 0

            case "--version":
                print(version)
                return 0

            case "--help", "-h":
                printUsage()
                return 0

            default:
                if !argument.hasPrefix("--") { inputs.append(argument) }
            }
            index += 1
        }

        guard !inputs.isEmpty else {
            printUsage()
            return 2
        }

        guard settings.format.isWritableBySystem else {
            fail("This Mac cannot write \(settings.format.displayName) files.")
        }
        settings.normalizeForFormat()

        let root = settings.resolvedOutputDirectory
        var failures = 0
        let cancellation = CancellationFlag()

        for input in inputs {
            let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                FileHandle.standardError.write("Not found: \(url.path)\n".data(using: .utf8)!)
                failures += 1
                continue
            }
            guard !isDirectory.boolValue else {
                FileHandle.standardError.write("Skipping directory: \(url.path)\n".data(using: .utf8)!)
                failures += 1
                continue
            }

            let document = SourceDocument.make(from: url)
            guard document.kind == .pdf else {
                FileHandle.standardError.write(
                    "Skipping \(url.lastPathComponent): only PDF input is supported in this build.\n"
                        .data(using: .utf8)!
                )
                failures += 1
                continue
            }

            let printer = ProgressPrinter(fileName: url.lastPathComponent)
            let observer = ConversionObserver(onProgress: { printer.report($0) })

            let result = ConversionEngine.convertPDFToImages(
                document: document,
                settings: settings,
                cancellation: cancellation,
                observer: observer
            )

            if let error = result.error {
                FileHandle.standardError.write("✗ \(url.lastPathComponent): \(error.message)\n".data(using: .utf8)!)
                failures += 1
            } else {
                print(
                    "✓ \(url.lastPathComponent) → \(result.producedCount) image(s)  \(result.outputFolder?.path ?? root.path)"
                )
            }
        }

        return failures == 0 ? 0 : 1
    }

    /// 逐页进度打印器。
    ///
    /// 做成引用类型而不是捕获局部变量，是为了不触发
    /// 「在并发执行代码中引用/修改被捕获的 var」这类 Swift 6 会变成错误的写法。
    private final class ProgressPrinter: @unchecked Sendable {
        private let fileName: String
        private var lastReported = -1

        init(fileName: String) {
            self.fileName = fileName
        }

        func report(_ progress: ConversionProgress) {
            guard progress.completedUnits != lastReported else { return }
            lastReported = progress.completedUnits
            let unit = progress.completedUnits
            let total = progress.totalUnits
            guard unit == 1 || unit == total || unit % 10 == 0 else { return }
            print("  … \(fileName) \(unit)/\(total)")
        }
    }

    // MARK: - 输出

    private static var allFormats: [ImageFormat] {
        FormatRegistry.allWritable
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private static func printFormats(includeAll: Bool) {
        let formats = includeAll ? FormatRegistry.allWritable : FormatRegistry.curated
        let width = formats.map(\.displayName.count).max() ?? 6
        for format in formats {
            let name = format.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(name)  .\(format.fileExtension)  \(format.summary)")
        }
        if let readOnly = FormatRegistry.readOnlyNotable.first {
            print(
                "\nRead-only on macOS (cannot be an output format): "
                    + FormatRegistry.readOnlyNotable.map(\.displayName).joined(separator: ", "))
            _ = readOnly
        }
    }

    private static func printDependencies() {
        // 外部工具探测在后续阶段接入；这里先固定输出占位结果。
        print("LibreOffice : not checked yet")
        print("pandoc      : not checked yet")
    }

    private static func printUsage() {
        print(
            """
            FormatSmith — convert PDF files to images from the command line.

              formatsmith --convert <a.pdf> [b.pdf …] [options]

            Options:
              --format <name>     Output format, e.g. \(FormatRegistry.curated.map(\.fileExtension).joined(separator: " | "))
              --quality <0.05-1>  Quality for lossy formats (default 0.9)
              --dpi <number>      Render at this DPI (default 200)
              --scale <number>    Render at this scale instead of DPI
              --pages <range>     Page range such as 1-3,5,8-10 (default: all)
              --out <dir>         Output directory (default: current directory)
              --pattern <pattern> File name template: {name} {page} {total} {date} {time}
              --background <c>    white | black | transparent
              --no-subfolder      Do not create a subfolder per source file
              --list-formats      List available output formats
              --check-dependencies  Report external tools (LibreOffice, pandoc)
              --version           Print version
              --help              Show this help

            Running without arguments opens the graphical app.
            """
        )
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        exit(2)
    }
}
