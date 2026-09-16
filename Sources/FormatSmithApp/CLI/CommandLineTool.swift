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

        // 必须先确认这次确实是命令行调用，再强制英文。
        // 顺序反了的话，图形界面也会被锁成英文 —— 语言开关就彻底失效了。
        guard LaunchMode.intent(arguments: arguments) == .commandLine else { return }

        // 命令行输出保持英文原文，避免脚本行为随系统语言变化。
        Localized.forcesBaseLanguage = true
        exit(run(arguments: arguments))
    }

    // MARK: - 解析与执行

    private static func run(arguments: [String]) -> Int32 {
        var inputs: [String] = []
        var settings = ConversionSettings()
        settings.outputDirectoryPath = FileManager.default.currentDirectoryPath
        settings.perFileSubfolder = false

        var index = 0
        var dpiWasSetExplicitly = false
        var scaleWasSetExplicitly = false
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
                    dpiWasSetExplicitly = true
                }

            case "--scale":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.resolutionMode = .scale
                    settings.scale = number
                    scaleWasSetExplicitly = true
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

            case "--id-photo":
                if let value = nextValue(argument) {
                    let key = value.lowercased()
                    guard
                        let size = IDPhotoSize.allCases.first(where: {
                            $0.cliName == key || $0.rawValue.lowercased() == key
                        })
                    else {
                        let names = IDPhotoSize.allCases.map(\.cliName).joined(separator: ", ")
                        fail("Unknown ID photo size: \(value). Use one of: \(names)")
                    }
                    settings.target = .image(settings.target.imageFormat ?? .jpeg)
                    settings.idPhotoEnabled = true
                    settings.idPhotoSize = size
                    settings.resolutionMode = .dpi
                    // 证件照的像素尺寸由毫米 × DPI 决定，用默认的 200 会得到非标准尺寸
                    if !dpiWasSetExplicitly { settings.dpi = 300 }
                }

            case "--id-bg":
                if let value = nextValue(argument), let background = IDPhotoBackground(rawValue: value.lowercased()) {
                    settings.idPhotoEnabled = true
                    settings.idPhotoBackground = background
                } else {
                    fail("Use --id-bg white, blue, red or keep.")
                }

            case "--no-face-crop":
                settings.idPhotoAutoCrop = false

            case "--sheet":
                if let value = nextValue(argument),
                    let sheet = PrintSheet.allCases.first(where: {
                        $0.cliName == value.lowercased() || $0.rawValue.lowercased() == value.lowercased()
                    })
                {
                    settings.printSheetEnabled = true
                    settings.printSheet = sheet
                } else {
                    fail("Use --sheet five-inch, six-inch or a4.")
                }

            case "--sheet-gap":
                if let value = nextValue(argument), let number = Double(value) {
                    settings.printSheetGapMM = max(0, number)
                }

            case "--no-cut-guides":
                settings.printSheetCutGuides = false

            case "--pdf-layout":
                if let value = nextValue(argument) {
                    let normalized = value.lowercased()
                    if normalized == "one" || normalized == "1" {
                        settings.pdfLayout = .onePerPage
                    } else if normalized == "two" || normalized == "2" {
                        settings.pdfLayout = .twoPerPage
                        settings.target = .pdf
                        // 一页两张需要固定纸张，与界面保持一致
                        if settings.pdfPageSize == .fitImage { settings.pdfPageSize = .a4 }
                    } else {
                        fail("Use --pdf-layout one or two.")
                    }
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

            case "--check-localization":
                printLocalization()
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
            case .pdf, .image, .office, .html, .markdown, .plainText:
                documents.append(document)
            case .unknown:
                FileHandle.standardError.write(
                    "Skipping \(url.lastPathComponent): unsupported input type.\n".data(using: .utf8)!
                )
                failures += 1
            }
        }

        guard !documents.isEmpty else {
            return failures == 0 ? 2 : 1
        }

        // DPI 是页面的概念：只对 PDF 有效。图片用的是倍数，别让它被静默忽略。
        if dpiWasSetExplicitly, !scaleWasSetExplicitly,
            documents.allSatisfy({ $0.kind.isImage }), !settings.idPhotoEnabled
        {
            FileHandle.standardError.write(
                "note: --dpi only affects PDF input; use --scale for images (1 = original size).\n"
                    .data(using: .utf8)!
            )
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
        // 走和界面同一套并发实现：这样冒烟测试才能真正覆盖到批量转换路径，
        // 顺带让「一次转几十个文件」在命令行里也快起来。
        let limit = ConversionEngine.automaticConcurrency(configured: settings.maxConcurrentFiles)
        let printer = ProgressPrinter(fileName: "\(documents.count) file(s)")

        let results: [ConversionResult]
        do {
            results = try MainThreadBridge.await {
                await ConversionEngine.convertBatch(
                    documents: documents,
                    target: settings.target,
                    settings: settings,
                    cancellation: cancellation,
                    maxConcurrency: limit,
                    observer: ConversionObserver(onProgress: { printer.report($0) })
                )
            }
        } catch {
            FileHandle.standardError.write("✗ \(error.localizedDescription)\n".data(using: .utf8)!)
            return documents.count
        }

        var failures = 0
        for result in results {
            let document = documents.first { $0.id == result.documentID }
            let name = document?.url.lastPathComponent ?? result.documentID.uuidString
            if let error = result.error {
                FileHandle.standardError.write("✗ \(name): \(error.message)\n".data(using: .utf8)!)
                failures += 1
            } else if result.outputFiles.count == 1, let output = result.outputFiles.first {
                // 单文件输出（提取、旋转、压缩、文档转 PDF）报文件本身
                print("✓ \(name) → \(output.path)")
            } else {
                let folder = result.outputFolder?.path ?? settings.resolvedOutputDirectory.path
                print("✓ \(name) → \(result.producedCount) file(s)  \(folder)")
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
        // 这是用户显式要求的动作，所以可以放心地起进程探测版本。
        print("Optional external tools (only needed for some document inputs):")
        for tool in ToolLocator.all() {
            print("  \(tool.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(tool.describe())")
            if !tool.isAvailable {
                print("               hint: \(tool.installHint)")
            }
        }
        print("\nWithout them: HTML, Markdown and plain text still convert (rendered by WebKit).")
    }

    private static func printLocalization() {
        // 用来确认应用包里确实带上了语言包，也方便翻译者核对。
        print("Languages bundled in this build: \(Localized.bundledLanguages().joined(separator: ", "))")
        let samples = ["Output format", "Merge", "Compress", "Missing tools", "Follow system"]
        for language in AppLanguage.allCases {
            print("\n\(language.displayName) [\(language.rawValue)]")
            for key in samples {
                print("  \(key)  →  \(Localized.resolve(key, in: language))")
            }
        }
    }

    private static func printUsage() {
        print(
            """
            FormatSmith — convert PDFs and images from the command line.

              formatsmith --convert <file> [more files…] --to <target> [options]

            Inputs:
              PDF, images, and documents (Office, HTML, Markdown, plain text → PDF).

            Targets:
              --to png | jpeg | heic | avif | tiff | gif | bmp | jp2 | psd | tga | exr | pbm | ico
              --to pdf              Combine images, run a PDF tool, or convert a document

            Options:
              --quality <0.05-1>    Quality for lossy formats (default 0.9)
              --dpi <number>        Render PDFs at this DPI (default 200). PDF input only
              --scale <number>      Output size factor for images: 1 = original, 2 = 200%
                                    (for PDF input this is an alternative to --dpi)
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
              ID photo:
              --id-photo <size>     \(IDPhotoSize.allCases.map(\.cliName).joined(separator: " | "))
              --id-bg <colour>      white | blue | red | keep   (default: white)
              --no-face-crop        Centre the photo instead of composing around the face
              --sheet <paper>       five-inch | six-inch | a4   (tile onto photo paper)
              --sheet-gap <mm>      Gap between photos on the sheet (default: 1)
              --no-cut-guides       Do not draw cut guides on the sheet

            PDF layout:
              --pdf-layout <n>      one | two  (two puts two images per page, e.g. ID front and back)

            Images to PDF:
              --pdf-page-size <s>   fit | a4 | letter   (default: fit)
              --pdf-margin <pt>     Margin for fixed page sizes (default: 24)
              --pdf-compress        JPEG-compress embedded images to shrink the PDF
              --merge / --no-merge  Merge several images into one PDF (default: merge)
              --list-formats        List available output formats
              --check-dependencies  Report external tools (LibreOffice, pandoc)
              --check-localization  Show how interface strings resolve per language
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
        private let label: String
        private let lock = NSLock()
        private var lastReported: [UUID: Int] = [:]

        init(fileName: String) {
            label = fileName
        }

        func report(_ progress: ConversionProgress) {
            let key = progress.documentID ?? UUID()
            let unit = progress.completedUnits
            let total = progress.totalUnits
            guard unit > 0, unit == 1 || unit == total || unit % 10 == 0 else { return }

            lock.lock()
            let previous = lastReported[key]
            guard previous != unit else {
                lock.unlock()
                return
            }
            lastReported[key] = unit
            lock.unlock()

            print("  … \(label) \(unit)/\(total)")
        }
    }
}
