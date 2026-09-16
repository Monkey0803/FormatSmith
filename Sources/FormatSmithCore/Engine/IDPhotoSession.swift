import CoreGraphics
import Foundation

/// 一次「证件照会话」：把原图解码、人脸、人像遮罩只算一次，之后换尺寸、换底色都很快。
///
/// 存在的理由有两个：
/// - **预览**：用户每改一次设置就重跑一遍 Vision 太浪费，实测 12MP 照片一次要 100ms 出头，
///   缓存住之后重新合成只要几毫秒，拖滑块才不会卡。
/// - **一致性**：预览与正式转换走的是同一个会话、同一套代码，预览看到的就是导出结果。
///
/// 线程安全：解码与分析在初始化时完成，遮罩按需计算并用锁保护，
/// 因此可以安全地在后台任务里复用（预览与转换都可能跨线程拿到它）。
public final class IDPhotoSession: @unchecked Sendable {

    private let source: CGImage
    private let analyzer: PersonMaskProviding

    private let lock = NSLock()
    /// nil 表示还没算过；`.some(nil)` 表示算过但没有结果。
    private var cachedFace: CGRect??
    private var cachedMask: CGImage??

    /// 原图像素尺寸。
    public var sourceSize: CGSize {
        CGSize(width: source.width, height: source.height)
    }

    public init(url: URL, analyzer: PersonMaskProviding = VisionPersonAnalyzer()) throws {
        self.source = try ImageDecoder.decode(url: url, scale: 1, maxPixels: 120_000_000)
        self.analyzer = analyzer
    }

    public init(image: CGImage, analyzer: PersonMaskProviding = VisionPersonAnalyzer()) {
        self.source = image
        self.analyzer = analyzer
    }

    /// 按给定设置渲染一张证件照。可以反复调用，代价很低。
    public func render(
        size: IDPhotoSize,
        background: IDPhotoBackground,
        dpi: Double,
        autoCrop: Bool = true
    ) throws -> IDPhotoProcessor.Outcome {
        try IDPhotoProcessor.render(
            source: source,
            size: size,
            background: background,
            dpi: dpi,
            autoCrop: autoCrop,
            faceBounds: autoCrop ? faceBounds() : nil,
            mask: background.requiresCutout ? personMask() : nil
        )
    }

    // MARK: - 缓存

    func faceBounds() -> CGRect? {
        lock.lock()
        if let cachedFace {
            lock.unlock()
            return cachedFace
        }
        lock.unlock()

        let detected = (try? analyzer.faceBounds(in: source)) ?? nil

        lock.lock()
        cachedFace = .some(detected)
        lock.unlock()
        return detected
    }

    func personMask() -> CGImage? {
        lock.lock()
        if let cachedMask {
            lock.unlock()
            return cachedMask
        }
        lock.unlock()

        let mask = (try? analyzer.personMask(for: source)) ?? nil

        lock.lock()
        cachedMask = .some(mask)
        lock.unlock()
        return mask
    }
}
