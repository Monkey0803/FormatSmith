import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 设置生效规则。
///
/// 一半是矩阵（哪些情况该生效），另一半更要紧：
/// **凡是判为「不生效」的设置，改动之后产出必须一模一样。**
/// 只有这样，「界面不显示」才等于「真的没影响」，而不是「偷偷生效」。
final class SettingsScopeTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let image = InputKind.image(identifier: "public.png")

    private func scope(
        _ kinds: [InputKind],
        target: OutputTarget,
        pageCounts: [Int] = [],
        idPhoto: Bool = false
    ) -> SettingsScope {
        var settings = ConversionSettings()
        settings.idPhotoEnabled = idPhoto
        return SettingsScope(
            documentKinds: kinds, pageCounts: pageCounts, target: target, settings: settings
        )
    }

    // MARK: - 矩阵

    func testIDPhotoIsActiveForImagesEvenWhenTheTargetIsPDF() {
        // 这正是「转 PDF 多了一层蓝色」的成因：设置在 PDF 目标下悄悄生效。
        // 现在它依然生效（图片可以按证件照规格出 PDF），但会被判定为 active，
        // 于是界面一定会把它显示出来。
        let pdfTarget = scope([image], target: .pdf)
        XCTAssertTrue(pdfTarget.isActive(.idPhoto))

        let imageTarget = scope([image], target: .image(.jpeg))
        XCTAssertTrue(imageTarget.isActive(.idPhoto))
    }

    func testIDPhotoIsInactiveWithoutImageInputs() {
        XCTAssertFalse(scope([.pdf], target: .pdf).isActive(.idPhoto))
        XCTAssertFalse(scope([.markdown], target: .pdf).isActive(.idPhoto))
    }

    func testPhotoSheetIsInactiveForPDFOutput() {
        XCTAssertFalse(scope([image], target: .pdf, idPhoto: true).isActive(.photoSheet))
        XCTAssertTrue(scope([image], target: .image(.jpeg), idPhoto: true).isActive(.photoSheet))
    }

    func testResolutionFollowsTheInputKind() {
        XCTAssertTrue(scope([image], target: .image(.jpeg)).isActive(.resolution))
        XCTAssertTrue(scope([.pdf], target: .image(.png)).isActive(.resolution))
        XCTAssertFalse(scope([.markdown], target: .pdf).isActive(.resolution))
    }

    func testResolutionIsInactiveForThePDFToolbox() {
        // 工具箱直接把 PDF 重新组织，不经过像素渲染，DPI 没有意义
        XCTAssertFalse(scope([.pdf], target: .pdf).isActive(.resolution))
        XCTAssertTrue(scope([.pdf], target: .image(.png)).isActive(.resolution))
    }

    func testQualityIsInactiveForPDFToPDF() {
        XCTAssertFalse(scope([.pdf], target: .pdf).isActive(.quality))
        XCTAssertTrue(scope([.pdf], target: .image(.jpeg)).isActive(.quality))
    }

    func testBackgroundIsInactiveWhileIDPhotoModeIsOn() {
        XCTAssertFalse(scope([image], target: .image(.jpeg), idPhoto: true).isActive(.background))
        XCTAssertTrue(scope([image], target: .image(.jpeg)).isActive(.background))
    }

    func testPageRangeNeedsSomethingMultiPage() {
        XCTAssertFalse(scope([image], target: .image(.jpeg)).isActive(.pageRange))
        XCTAssertTrue(scope([.pdf], target: .image(.png), pageCounts: [3]).isActive(.pageRange))
        XCTAssertFalse(scope([.pdf], target: .image(.png), pageCounts: [1]).isActive(.pageRange))
    }

    func testPageRangeIsOnlyActiveForExtractInTheToolbox() {
        // 合并/压缩/旋转都是整份文件重新组织，页码对它们没有意义；
        // 这条规则必须与引擎一致，否则界面又会「显示了却不起作用」。
        func toolbox(_ tool: PDFTool) -> SettingsScope {
            var settings = ConversionSettings()
            settings.pdfTool = tool
            return SettingsScope(
                documentKinds: [.pdf], pageCounts: [5], target: .pdf, settings: settings
            )
        }

        XCTAssertTrue(toolbox(.extract).isActive(.pageRange))
        XCTAssertFalse(toolbox(.merge).isActive(.pageRange))
        XCTAssertFalse(toolbox(.compress).isActive(.pageRange))
        XCTAssertFalse(toolbox(.rotate).isActive(.pageRange))
        XCTAssertFalse(toolbox(.split).isActive(.pageRange))
    }

    func testChangingThePageRangeDoesNotAffectMergeOutput() throws {
        // 上一条规则的可执行版本：判为不生效，就必须真的不影响产出
        let first = try FixtureFactory.makePDF(pages: 3, named: "a", in: directory)
        let second = try FixtureFactory.makePDF(pages: 3, named: "b", in: directory)

        func merge(range: String?) throws -> Data {
            var settings = ConversionSettings()
            settings.target = .pdf
            settings.pdfTool = .merge
            settings.outputDirectoryPath = output.path
            settings.perFileSubfolder = false
            settings.filenamePattern = "merged"
            if let range {
                settings.pageRangeMode = .custom
                settings.pageRangeText = range
            }
            let result = ConversionEngine.runPDFTool(
                documents: [SourceDocument.make(from: first), SourceDocument.make(from: second)],
                tool: .merge,
                settings: settings,
                cancellation: CancellationFlag()
            )
            XCTAssertNil(result.error)
            return try renderedPDF(try XCTUnwrap(result.outputFiles.first))
        }

        XCTAssertEqual(try merge(range: nil), try merge(range: "1-2"), "合并时页码不该起作用")
    }

    func testPDFFeaturesNeedPDFInputAndPDFTarget() {
        XCTAssertTrue(scope([.pdf], target: .pdf).isActive(.pdfTool))
        XCTAssertFalse(scope([.pdf], target: .image(.png)).isActive(.pdfTool))
        XCTAssertFalse(scope([image], target: .pdf).isActive(.pdfTool))

        XCTAssertTrue(scope([image], target: .pdf).isActive(.pdfLayout))
        XCTAssertFalse(scope([image], target: .image(.jpeg)).isActive(.pdfLayout))
    }

    // MARK: - 「不生效」必须真的不生效

    /// 转换一次，返回**渲染后的像素**。
    ///
    /// 不直接比文件字节：PDF 里带创建时间戳，两次导出必然不同，
    /// 那样比出来的差异说明不了任何问题。渲染成像素才是真正「看起来一样」。
    private func produce(
        _ url: URL,
        target: OutputTarget,
        settings configure: (inout ConversionSettings) -> Void
    ) throws -> Data {
        var settings = ConversionSettings()
        settings.target = target
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        configure(&settings)

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: target,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error, "转换失败：\(result.error?.message ?? "")")
        let file = try XCTUnwrap(result.outputFiles.first)

        if target.isPDF {
            return try renderedPDF(file)
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try pixels(of: image)
    }

    /// 把 PDF 的每一页渲染出来，拼成一份用于比较的数据。
    private func renderedPDF(_ url: URL) throws -> Data {
        let pdf = try PDFRasterizer.open(url)
        var combined = Data()
        for index in 1...max(pdf.numberOfPages, 1) {
            guard let page = pdf.page(at: index) else { continue }
            let image = try PDFRasterizer.render(
                page: page, scale: 1, background: .white, format: .png, maxPixels: 40_000_000
            )
            combined.append(try pixels(of: image))
        }
        return combined
    }

    private func pixels(of image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes)
    }

    func testTurningOnPhotoSheetDoesNotChangePDFOutput() throws {
        let url = try FixtureFactory.makeImage(width: 1200, height: 900, named: "photo", in: directory)
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.idPhotoEnabled = true
        let kinds = [InputKind.image(identifier: "public.png")]

        let scope = SettingsScope(
            documentKinds: kinds, target: .pdf, settings: settings
        )
        XCTAssertFalse(scope.isActive(.photoSheet), "前提：PDF 目标下相纸排版不生效")

        let off = try produce(url, target: .pdf) { settings in
            settings.idPhotoEnabled = true
            settings.printSheetEnabled = false
        }
        let on = try produce(url, target: .pdf) { settings in
            settings.idPhotoEnabled = true
            settings.printSheetEnabled = true
            settings.printSheet = .sixInch
        }

        XCTAssertEqual(off, on, "判为不生效的相纸排版，开了也不该改变 PDF")
    }

    func testBackgroundDoesNotAffectIDPhotoOutput() throws {
        let url = try FixtureFactory.makeImage(width: 1200, height: 900, named: "photo", in: directory)
        let target = OutputTarget.image(.jpeg)
        let kinds = [InputKind.image(identifier: "public.png")]

        var settings = ConversionSettings()
        settings.idPhotoEnabled = true
        XCTAssertFalse(
            SettingsScope(documentKinds: kinds, target: target, settings: settings).isActive(.background),
            "前提：证件照模式下「透明铺底」不生效"
        )

        let white = try produce(url, target: target) { settings in
            settings.idPhotoEnabled = true
            settings.idPhotoBackground = .blue
            settings.background = .white
        }
        let transparent = try produce(url, target: target) { settings in
            settings.idPhotoEnabled = true
            settings.idPhotoBackground = .blue
            settings.background = .transparent
        }

        XCTAssertEqual(white, transparent, "底色由证件照规格决定，透明铺底不该影响结果")
    }

    func testPageRangeDoesNotAffectSinglePageImages() throws {
        let url = try FixtureFactory.makeImage(width: 400, height: 300, named: "img", in: directory)
        let target = OutputTarget.image(.png)
        let kinds = [InputKind.image(identifier: "public.png")]

        let scope = SettingsScope(
            documentKinds: kinds, pageCounts: [1], target: target, settings: ConversionSettings()
        )
        XCTAssertFalse(scope.isActive(.pageRange), "前提：单页图片谈不上页码范围")

        let all = try produce(url, target: target) { settings in
            settings.pageRangeMode = .all
        }
        let custom = try produce(url, target: target) { settings in
            settings.pageRangeMode = .custom
            settings.pageRangeText = "2-3"
        }

        XCTAssertEqual(all, custom, "图片只有一页，页码范围不该改变结果")
    }

    func testActiveSettingsDoChangeOutput() throws {
        // 反向验证：判为生效的设置必须真的能改变产出，
        // 否则「生效」这个词就失去意义了（测试也就成了摆设）。
        let url = try FixtureFactory.makeImage(width: 1200, height: 900, named: "photo", in: directory)
        let target = OutputTarget.image(.png)

        let small = try produce(url, target: target) { settings in
            settings.maxLongEdge = 300
        }
        let large = try produce(url, target: target) { settings in
            settings.maxLongEdge = 0
        }
        XCTAssertNotEqual(small, large, "最长边是生效的，改了它产出就该不同")
    }
}

/// 规则写了却没用上，等于没写。
///
/// 每个设置项都必须真的被界面（或引擎）查询过生效性；
/// 只加规则、忘了接线，就又回到「显示了却不起作用」的老路上。
final class SettingsScopeWiringTests: XCTestCase {

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FormatSmithCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根目录
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testEveryFeatureIsConsultedByThePanel() throws {
        let panel = try sourceText("Sources/FormatSmithApp/Views/Panels/ConversionSettingsPanel.swift")

        for feature in SettingsScope.Feature.allCases {
            XCTAssertTrue(
                panel.contains("isActive(.\(feature.rawValue))"),
                "设置项 \(feature.rawValue) 的生效规则没有被界面使用；"
                    + "要么接到分区显隐上，要么从规则里去掉"
            )
        }
    }

    func testScopeIsBuiltFromRealQueueContents() throws {
        // 规则必须按队列实际情况构造，而不是写死几个布尔值
        let model = try sourceText("Sources/FormatSmithApp/ConverterModel.swift")
        XCTAssertTrue(model.contains("SettingsScope("))
        XCTAssertTrue(model.contains("convertibleItems.map(\\.document.kind)"))
    }
}
