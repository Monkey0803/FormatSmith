import CoreGraphics
import Foundation
import Vision

/// 提供人像遮罩。
///
/// 抽成协议是为了让几何计算能被测试：真机上的 Vision 只认真人照片，
/// 用合成图测不出裁剪与合成的对错，测试里换成固定遮罩就能逐像素断言。
public protocol PersonMaskProviding: Sendable {
    /// 返回人像遮罩：越大越「是人」，尺寸不必与原图一致。找不到人像返回 nil。
    func personMask(for image: CGImage) throws -> CGImage?

    /// 返回人脸框（归一化，原点在左下），找不到返回 nil。
    func faceBounds(in image: CGImage) throws -> CGRect?
}

/// 用系统 Vision 框架实现：人像分割 + 人脸检测。
public struct VisionPersonAnalyzer: PersonMaskProviding {

    public init() {}

    public func personMask(for image: CGImage) throws -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        return Self.grayImage(from: buffer)
    }

    public func faceBounds(in image: CGImage) throws -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        // 一张照片里可能有多个人，取面积最大的那个作为主体
        let boxes = (request.results ?? []).map(\.boundingBox)
        return boxes.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 把 OneComponent8 的像素缓冲拷成无 alpha 的灰度 CGImage。
    ///
    /// `CGContext.clip(to:mask:)` 要求遮罩是 DeviceGray 且不带 alpha。
    /// 这里拷贝一份数据而不是直接引用缓冲区，免得解锁之后图像失效。
    static func grayImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }

        let byteCount = bytesPerRow * height
        let data = Data(bytes: base, count: byteCount)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// 把一张照片做成合规的证件照。
public enum IDPhotoProcessor {

    /// 人脸宽度占整张照片宽度的比例。证件照的常见构图：头部约占画面宽度的 55% 左右。
    static let faceWidthRatio = 0.55
    /// 人脸中心距顶部的比例。留出头顶空间，不至于「顶天」。
    static let faceCenterYRatio = 0.44

    public struct Outcome: Sendable {
        public let image: CGImage
        /// 是否真的换了底色（没检测到人像时为 false）。
        public let replacedBackground: Bool
        /// 是否用了人脸来做构图。
        public let usedFace: Bool
        /// 需要告诉用户的提示，例如「没检测到人像，已保留原背景」。
        /// 预览与正式转换共用同一套文案，免得两处说法不一致。
        public let notes: [String]

        public init(
            image: CGImage,
            replacedBackground: Bool,
            usedFace: Bool,
            notes: [String] = []
        ) {
            self.image = image
            self.replacedBackground = replacedBackground
            self.usedFace = usedFace
            self.notes = notes
        }
    }

    /// 生成证件照。
    ///
    /// 只做一次转换时用这个就好；需要反复调整参数（比如界面预览）请改用 `IDPhotoSession`，
    /// 它会把解码、人脸、遮罩缓存住，后续重算只要几毫秒。
    ///
    /// - Parameters:
    ///   - background: `.keep` 只裁剪缩放；其余颜色会先抠人像再铺底。
    ///   - autoCrop: 是否按人脸构图；关闭时整张图等比缩放居中。
    public static func makeIDPhoto(
        from url: URL,
        size: IDPhotoSize,
        background: IDPhotoBackground,
        dpi: Double,
        autoCrop: Bool = true,
        analyzer: PersonMaskProviding = VisionPersonAnalyzer()
    ) throws -> Outcome {
        let session = try IDPhotoSession(url: url, analyzer: analyzer)
        return try session.render(size: size, background: background, dpi: dpi, autoCrop: autoCrop)
    }

    /// 直接用一张已经解码好的图片生成证件照（测试与已持有 CGImage 的调用方使用）。
    public static func makeIDPhoto(
        from source: CGImage,
        size: IDPhotoSize,
        background: IDPhotoBackground,
        dpi: Double,
        autoCrop: Bool = true,
        analyzer: PersonMaskProviding = VisionPersonAnalyzer()
    ) throws -> Outcome {
        let session = IDPhotoSession(image: source, analyzer: analyzer)
        return try session.render(size: size, background: background, dpi: dpi, autoCrop: autoCrop)
    }

    /// 真正干活的地方：人脸框与遮罩由调用方提供，便于复用与测试。
    static func render(
        source: CGImage,
        size: IDPhotoSize,
        background: IDPhotoBackground,
        dpi: Double,
        autoCrop: Bool,
        faceBounds: CGRect?,
        mask providedMask: CGImage?
    ) throws -> Outcome {
        let pixels = size.pixelSize(dpi: dpi)
        let canvas = CGSize(width: pixels.width, height: pixels.height)
        let imageSize = CGSize(width: source.width, height: source.height)
        guard imageSize.width > 0, imageSize.height > 0 else {
            throw ConversionError(Localized.text("This image has no pixels to work with."))
        }

        let placement = placement(
            imageSize: imageSize,
            faceBounds: faceBounds,
            canvas: canvas
        )
        let usedFace = faceBounds != nil

        // 要换底色才需要遮罩；拿不到就退回「整张缩放居中」，绝不把整张照片涂掉。
        let mask = background.requiresCutout ? providedMask : nil

        let wantsAlpha = false
        let context = try BitmapContext.make(
            width: pixels.width,
            height: pixels.height,
            wantsAlpha: wantsAlpha
        )

        if let backgroundColour = background.color {
            context.setFillColor(backgroundColour)
            context.fill(CGRect(origin: .zero, size: canvas))
        } else {
            context.fill(with: .white)
        }
        context.interpolationQuality = .high

        let target = CGRect(origin: .zero, size: canvas)

        if let mask, background.requiresCutout {
            // 抠人像：遮罩会被拉伸到同一个矩形，所以不必预先缩放到原图尺寸
            context.saveGState()
            context.clip(to: placement, mask: mask)
            context.draw(source, in: placement)
            context.restoreGState()
            return Outcome(
                image: try makeImage(from: context),
                replacedBackground: true,
                usedFace: usedFace,
                notes: notesFor(usedFace: usedFace, wantsCutout: true, replacedBackground: true)
            )
        }

        if background.requiresCutout {
            // 要换底色但没检测到人像：整张图缩放到画面内居中，不铺底色以外的处理
            let fitted = containRect(imageSize: imageSize, in: canvas)
            context.draw(source, in: fitted)
            return Outcome(
                image: try makeImage(from: context),
                replacedBackground: false,
                usedFace: usedFace,
                notes: notesFor(
                    usedFace: usedFace,
                    wantsCutout: background.requiresCutout,
                    replacedBackground: false
                )
            )
        }

        // 保留原背景：裁剪出算好的区域再铺满整张画布
        let crop = placement.clamped(to: CGRect(origin: .zero, size: imageSize))
        guard crop.width > 0, crop.height > 0 else {
            throw ConversionError(Localized.text("This photo is too small for the selected size."))
        }
        context.saveGState()
        context.scaleBy(x: target.width / crop.width, y: target.height / crop.height)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.draw(source, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()

        return Outcome(
            image: try makeImage(from: context),
            replacedBackground: false,
            usedFace: usedFace,
            notes: notesFor(
                usedFace: usedFace,
                wantsCutout: background.requiresCutout,
                replacedBackground: false
            )
        )
    }

    /// 拼出要告诉用户的提示。
    static func notesFor(usedFace: Bool, wantsCutout: Bool, replacedBackground: Bool) -> [String] {
        var notes: [String] = []
        if wantsCutout, !replacedBackground {
            notes.append(Localized.text("No person was detected, so the original background was kept."))
        }
        if !usedFace {
            notes.append(Localized.text("No face was detected, so the photo was centred instead."))
        }
        return notes
    }

    // MARK: - 构图

    /// 算出「原图该画在哪」：原点在左下，与绘图坐标系一致。
    ///
    /// 有脸时让人脸位于指定比例处；没脸时整张图缩放到画面内居中。
    static func placement(imageSize: CGSize, faceBounds: CGRect?, canvas: CGSize) -> CGRect {
        guard let faceBounds, faceBounds.width > 0 else {
            return containRect(imageSize: imageSize, in: canvas)
        }

        let faceWidthInImage = faceBounds.width * imageSize.width
        guard faceWidthInImage > 0 else {
            return containRect(imageSize: imageSize, in: canvas)
        }

        let scale = (faceWidthRatio * canvas.width) / faceWidthInImage
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        // 人脸中心（原图坐标，原点左下）
        let faceCentre = CGPoint(
            x: faceBounds.midX * imageSize.width * scale,
            y: faceBounds.midY * imageSize.height * scale
        )

        return CGRect(
            x: canvas.width / 2 - faceCentre.x,
            y: (1 - faceCenterYRatio) * canvas.height - faceCentre.y,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// 等比缩放到画面内并居中。
    static func containRect(imageSize: CGSize, in canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func makeImage(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw ConversionError(Localized.text("Rendering failed."))
        }
        return image
    }
}

extension CGRect {
    /// 把矩形夹回给定范围内。
    func clamped(to bounds: CGRect) -> CGRect {
        let width = min(self.width, bounds.width)
        let height = min(self.height, bounds.height)
        let x = min(max(minX, bounds.minX), bounds.maxX - width)
        let y = min(max(minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
