import AppKit
import FormatSmithCore
import Foundation

/// 命令行模式：同一个二进制既能开窗口，也能被脚本调用。
///
///     formatsmith --convert a.pdf b.jpg --to png --dpi 150 --out ~/Desktop/out
///     formatsmith --convert a.jpg b.png --to pdf --out ~/Desktop/album.pdf
///
/// 约定：数据走 stdout、诊断走 stderr；退出码 0 成功 / 1 部分失败 / 2 参数错误。
enum CommandLineTool {

    static func runIfNeeded() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // 命令行输出保持英文原文，避免脚本行为随系统语言变化。
        Localized.forcesBaseLanguage = true
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
        settings.perFileSubfolder = false

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
                    if key == "pdf" {
                        settings.target = .pdf
                    } else if let format = allFormats.first(where: {
                        $0.identifier == key || $0.fileExtension == key || $0.displayName.lowercased() == key
                    }) {
                        settings.target = .image(format)
                    } else if let readOnly = FormatRegistry.readOnlyNotable.first(where: {
                        $0.displayName.lowercased() == key || $0.fileExtension == key
                    }) {
                        fail(
                            "\(readOnly.displayName) can be read by macOS but not written, "
                                + "so it cannot be an output format. Try --list-formats."
                        )
                    } else {
                        fail("Unknown format: \(value). Try --list-formats.")
                    }
                }

            case "--quality":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.quality = min(max(number, 0.05), 1)
                    settings.pdfImageQuality = min(max(number, 0.2), 1)
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

            case "--pdf-page-size":
                if let value = nextValue(argument), let size = PDFPageSize(rawValue: value.lowercased()) {
                    settings.pdfPageSize = size
                }

            case "--pdf-margin":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.pdfMargin = max(0, number)
                }

            case "--pdf-tool":
                if let value = nextValue(argument) {
                    guard let tool = PDFTool(rawValue: value.lowercased()) else {
                        fail("Unknown PDF tool: \(value). Use merge, split, extract, rotate or compress.")
                    }
                    settings.target = .pdf
                    settings.pdfTool = tool
                }

            case "--split-every":
                if let value = nextValue(argument), let number = Int(value) {
                    settings.splitEveryPages = max(1, number)
                }

            case "--rotate":
                if let value = nextValue(argument), let degrees = Int(value) {
                    let normalized = ((degrees % 360) + 360) % 360
                    guard let angle = RotationAngle(rawValue: normalized) else {
                        fail("Rotation must be 90, 180 or 270 degrees.")
                    }
                    settings.target = .pdf
                    settings.pdfTool = .rotate
                    settings.rotationAngle = angle
                }

            case "--pdf-compress":
                settings.pdfCompressesImages = true

            case "--merge":
                settings.mergeImagesIntoOnePDF = true

            case "--no-merge":
                settings.mergeImagesIntoOnePDF = false

            case "--no-subfolder":
                settings.perFileSubfolder = false

            case "--subfolder":
                settings.perFileSubfolder = true

            case "--list-formats":
                printFormats()
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

        if let format = settings.target.imageFormat, !format.isWritableBySystem {
            fail("This Mac cannot write \(format.displayName) files.")
        }
        settings.normalizeForFormat()

        let cancellation = CancellationFlag()
        var documents: [SourceDocument] = []
        var failures = 0

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
            switch document.kind {
            case .pdf, .image:
                documents.append(document)
            default:
                FileHandle.standardError.write(
                    "Skipping \(url.lastPathComponent): \(document.kind.displayName) input is not supported yet.\n"
                        .data(using: .utf8)!
                )
                failures += 1
            }
        }

        guard !documents.isEmpty else {
            return failures == 0 ? 2 : 1
        }

        let strategy = ConversionRouter.strategy(
            inputs: documents.map(\.kind),
            target: settings.target,
            mergesImages: settings.mergeImagesIntoOnePDF
        )

        if strategy == .imagesToOnePDF {
            failures += mergeIntoOnePDF(documents: documents, settings: settings, cancellation: cancellation)
        } else if strategy == .pdfToolbox, settings.pdfTool.operatesOnWholeBatch, documents.count > 1 {
            failures += runPDFToolOnBatch(documents: documents, settings: settings, cancellation: cancellation)
        } else {
            failures += convertIndividually(documents: documents, settings: settings, cancellation: cancellation)
        }

        return failures == 0 ? 0 : 1
    }

    // MARK: - 执行

    private static func convertIndividually(
        documents: [SourceDocument],
        settings: ConversionSettings,
        cancellation: CancellationFlag
    ) -> Int {
        var failures = 0

        for (index, document) in documents.enumerated() {
            let printer = ProgressPrinter(fileName: document.url.lastPathComponent)
            let observer = ConversionObserver(onProgress: { printer.report($0) })

            let result = ConversionEngine.convert(
                document: document,
                target: settings.target,
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: index,
                fileCount: documents.count
            )

            if let error = result.error {
                FileHandle.standardError.write(
                    "✗ \(document.url.lastPathComponent): \(error.message)\n".data(using: .utf8)!)
                failures += 1
            } else if result.outputFiles.count == 1, let output = result.outputFiles.first {
                // 单文件输出（提取、旋转、压缩、图片转 PDF）报文件本身，别报「1 个文件」
                print("✓ \(document.url.lastPathComponent) → \(output.path)")
            } else {
                let folder = result.outputFolder?.path ?? settings.resolvedOutputDirectory.path
                print("✓ \(document.url.lastPathComponent) → \(result.producedCount) file(s)  \(folder)")
            }
        }
        return failures
    }

    private static func mergeIntoOnePDF(
        documents: [SourceDocument],
        settings: ConversionSettings,
        cancellation: CancellationFlag
    ) -> Int {
        let printer = ProgressPrinter(fileName: "\(documents.count) images")
        let observer = ConversionObserver(onProgress: { printer.report($0) })

        let result = ConversionEngine.composePDF(
            documents: documents,
            settings: settings,
            cancellation: cancellation,
            observer: observer
        )

        if let error = result.error {
            FileHandle.standardError.write("✗ merge failed: \(error.message)\n".data(using: .utf8)!)
            return 1
        }
        if let output = result.outputFiles.first {
            print("✓ merged \(documents.count) image(s) → \(output.path)")
        }
        return 0
    }

    private static func runPDFToolOnBatch(
        documents: [SourceDocument],
        settings: ConversionSettings,
        cancellation: CancellationFlag
    ) -> Int {
        let printer = ProgressPrinter(fileName: "\(documents.count) PDFs")
        let observer = ConversionObserver(onProgress: { printer.report($0) })

        let result = ConversionEngine.runPDFTool(
            documents: documents,
            tool: settings.pdfTool,
            settings: settings,
            cancellation: cancellation,
            observer: observer
        )

        if let error = result.error {
            FileHandle.standardError.write(
                "✗ \(settings.pdfTool.rawValue) failed: \(error.message)\n".data(using: .utf8)!)
            return 1
        }
        for url in result.outputFiles {
            print("✓ \(settings.pdfTool.rawValue) → \(url.path)")
        }
        return 0
    }

    // MARK: - 输出

    private static var allFormats: [ImageFormat] {
        FormatRegistry.allWritable
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private static func printFormats() {
        let formats = FormatRegistry.allWritable
        let width = formats.map(\.displayName.count).max() ?? 6
        for format in formats {
            let name = format.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(name)  .\(format.fileExtension)  \(format.summary)")
        }
        print("\nPDF can also be used as a target: --to pdf")
        if !FormatRegistry.readOnlyNotable.isEmpty {
            let names = FormatRegistry.readOnlyNotable.map(\.displayName).joined(separator: ", ")
            print("Readable but not writable on macOS: \(names)")
        }
    }

    private static func printDependencies() {
        // 外部工具探测（LibreOffice / pandoc）在文档转换阶段接入。
        print("LibreOffice : not checked yet")
        print("pandoc      : not checked yet")
    }

    private static func printUsage() {
        print(
            """
            FormatSmith — convert PDFs and images from the command line.

              formatsmith --convert <file> [more files…] --to <target> [options]

            Targets:
              --to png | jpeg | heic | avif | tiff | gif | bmp | jp2 | psd | tga | exr | pbm | ico
              --to pdf              Combine images (or convert single files) into PDF

            Options:
              --quality <0.05-1>    Quality for lossy formats (default 0.9)
              --dpi <number>        Render PDFs at this DPI (default 200); 72 = original size for images
              --scale <number>      Scale factor instead of DPI, e.g. 2 for 200%
              --pages <range>       PDF page range such as 1-3,5,8-10 (default: all)
              --out <dir>           Output directory (default: current directory)
              --pattern <template>  {name} {page} {total} {date} {time}
              --background <c>      white | black | transparent
              --subfolder           Create a subfolder per source file
              PDF toolbox (input and output are both PDF):
              --pdf-tool <tool>     merge | split | extract | rotate | compress
              --split-every <n>     Pages per file when splitting (default 1)
              --rotate <deg>        90 | 180 | 270
              --pages <range>       Page range used by --pdf-tool extract

            Images to PDF:
              --pdf-page-size <s>   fit | a4 | letter   (default: fit)
              --pdf-margin <pt>     Margin for fixed page sizes (default: 24)
              --pdf-compress        JPEG-compress embedded images to shrink the PDF
              --merge / --no-merge  Merge several images into one PDF (default: merge)
              --list-formats        List available output formats
              --check-dependencies  Report external tools (LibreOffice, pandoc)
              --version             Print version
              --help                Show this help

            Running without arguments opens the graphical app.
            """
        )
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        exit(2)
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
            guard unit > 0 else { return }
            guard unit == 1 || unit == total || unit % 10 == 0 else { return }
            print("  … \(fileName) \(unit)/\(total)")
        }
    }
}
