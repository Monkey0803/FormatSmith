import XCTest
@testable import FormatSmithCore

final class FormatRegistryTests: XCTestCase {

    func testCuratedFormatsAreAllWritableOnThisSystem() {
        let curated = FormatRegistry.curated
        XCTAssertFalse(curated.isEmpty)
        for format in curated {
            XCTAssertTrue(format.isWritableBySystem, "\(format.identifier) 声称精选，却写不出来")
        }
    }

    func testCuratedOrderIsStable() {
        // UI 依赖这个顺序；调整它应当是有意为之，而不是无意中被改掉。
        XCTAssertEqual(
            FormatRegistry.curated.map(\.identifier),
            [
                "public.png", "public.jpeg", "public.heic", "public.avif", "public.tiff", "com.compuserve.gif",
                "com.microsoft.bmp",
            ]
        )
    }

    func testAllWritableIsSupersetOfCurated() {
        let curated = Set(FormatRegistry.curated.map(\.identifier))
        let all = Set(FormatRegistry.allWritable.map(\.identifier))
        XCTAssertTrue(curated.isSubset(of: all))
    }

    func testAllWritableHasNoDuplicates() {
        let identifiers = FormatRegistry.allWritable.map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    func testPDFIsNotOfferedAsAnImageFormat() {
        XCTAssertFalse(FormatRegistry.allWritable.contains(ImageFormat("com.adobe.pdf")))
        XCTAssertFalse(FormatRegistry.curated.contains(ImageFormat("com.adobe.pdf")))
    }

    func testLongTailFormatsArePresentWhenTheSystemSupportsThem() {
        // 这些是 macOS 一直支持的格式，出现说明长尾清单接对了。
        let identifiers = Set(FormatRegistry.allWritable.map(\.identifier))
        for expected in [
            "com.microsoft.ico", "public.jpeg-2000", "com.adobe.photoshop-image", "com.truevision.tga-image",
        ] {
            if FormatRegistry.writableIdentifiers.contains(expected) {
                XCTAssertTrue(identifiers.contains(expected), "\(expected) 应出现在全部格式里")
            }
        }
    }

    // MARK: - 能力标记

    func testAlphaCapability() {
        XCTAssertTrue(ImageFormat.png.supportsAlpha)
        XCTAssertTrue(ImageFormat.tiff.supportsAlpha)
        XCTAssertTrue(ImageFormat.gif.supportsAlpha)
        XCTAssertFalse(ImageFormat.jpeg.supportsAlpha)
        XCTAssertFalse(ImageFormat.bmp.supportsAlpha)
    }

    func testUnknownFormatsAreTreatedAsOpaque() {
        // 宁可多铺一层背景，也不要写出「本该透明却变黑」的图。
        let unknown = ImageFormat("com.example.not-a-real-format")
        XCTAssertFalse(unknown.supportsAlpha)
        XCTAssertFalse(unknown.supportsQuality)
    }

    func testLossyCapability() {
        XCTAssertTrue(ImageFormat.jpeg.supportsQuality)
        XCTAssertTrue(ImageFormat.heic.supportsQuality)
        XCTAssertTrue(ImageFormat.avif.supportsQuality)
        XCTAssertTrue(ImageFormat.jpeg2000.supportsQuality)
        XCTAssertFalse(ImageFormat.png.supportsQuality)
        XCTAssertFalse(ImageFormat.tiff.supportsQuality)
        XCTAssertFalse(ImageFormat.bmp.supportsQuality)
    }

    func testFileExtensions() {
        XCTAssertEqual(ImageFormat.png.fileExtension, "png")
        XCTAssertEqual(ImageFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ImageFormat.heic.fileExtension, "heic")
        XCTAssertEqual(ImageFormat.tiff.fileExtension, "tiff")
    }

    func testDisplayNames() {
        XCTAssertEqual(ImageFormat.png.displayName, "PNG")
        XCTAssertEqual(ImageFormat.jpeg.displayName, "JPEG")
        XCTAssertEqual(ImageFormat.jpeg2000.displayName, "JPEG 2000")
        XCTAssertEqual(ImageFormat("com.microsoft.ico").displayName, "Windows Icon")
    }

    func testMenuLabelContainsNameAndExtension() {
        XCTAssertEqual(ImageFormat.png.menuLabel, "PNG  ·  .png")
    }

    // MARK: - 只读格式

    func testReadOnlyFormatsAreReadableButNotWritable() {
        // WebP / JPEG XL 在 macOS 上只能读不能写，是「为什么不能导出 WebP」的依据。
        for format in FormatRegistry.readOnlyNotable {
            XCTAssertTrue(format.isReadableBySystem, "\(format.identifier) 应当可读")
            XCTAssertFalse(format.isWritableBySystem, "\(format.identifier) 不应可写")
        }
    }

    func testSystemCapabilitySetsAreNotEmpty() {
        XCTAssertFalse(FormatRegistry.writableIdentifiers.isEmpty)
        XCTAssertFalse(FormatRegistry.readableIdentifiers.isEmpty)
        // 可写集合不必是可读集合的子集：两个清单由系统独立给出
        // （例如 ASTC 能写但不在可读清单里），这里只要求常用格式两头都在。
        for identifier in FormatRegistry.curatedOrder {
            XCTAssertTrue(FormatRegistry.writableIdentifiers.contains(identifier), "\(identifier) 应可写")
            XCTAssertTrue(FormatRegistry.readableIdentifiers.contains(identifier), "\(identifier) 应可读")
        }
    }

    func testCuratedExtensionsMatchUserExpectations() {
        // 系统对 JPEG 给的扩展名是 "jpeg"，我们统一成 "jpg"。
        let extensions = Dictionary(
            uniqueKeysWithValues: FormatRegistry.curated.map { ($0.identifier, $0.fileExtension) })
        XCTAssertEqual(extensions["public.png"], "png")
        XCTAssertEqual(extensions["public.jpeg"], "jpg")
        XCTAssertEqual(extensions["public.heic"], "heic")
        XCTAssertEqual(extensions["public.avif"], "avif")
        XCTAssertEqual(extensions["public.tiff"], "tiff")
        XCTAssertEqual(extensions["com.compuserve.gif"], "gif")
        XCTAssertEqual(extensions["com.microsoft.bmp"], "bmp")
    }

    func testTextureContainerFormatsAreNotOffered() {
        // DDS/KTX/ASTC/PVR 这类游戏纹理容器不是通用图片格式，刻意不提供。
        let offered = Set(FormatRegistry.allWritable.map(\.identifier))
        for excluded in [
            "com.microsoft.dds", "org.khronos.ktx", "org.khronos.ktx2", "org.khronos.astc", "public.pvr",
            "com.apple.atx", "com.apple.icns",
        ] {
            XCTAssertFalse(offered.contains(excluded), "\(excluded) 不应出现在输出格式里")
        }
    }

    func testPixelConstraintRules() {
        let ico = ImageFormat("com.microsoft.ico")
        XCTAssertEqual(ico.pixelConstraint, .square(sideRange: 16...256))
        XCTAssertTrue(ico.pixelConstraint.allows(width: 64, height: 64))
        XCTAssertFalse(ico.pixelConstraint.allows(width: 64, height: 48), "非正方形应被拒绝")
        XCTAssertFalse(ico.pixelConstraint.allows(width: 8, height: 8), "过小应被拒绝")
        XCTAssertFalse(ico.pixelConstraint.allows(width: 512, height: 512), "过大应被拒绝")

        XCTAssertEqual(ImageFormat.png.pixelConstraint, .none)
        XCTAssertTrue(ImageFormat.png.pixelConstraint.allows(width: 1920, height: 1080))
    }
}
