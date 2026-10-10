import CoreGraphics
import Foundation
import Vision

/// 识别出来的一行文字。
public struct RecognizedLine: Equatable, Sendable {
    public let text: String
    /// 归一化矩形（原点左下），与 Vision 的约定一致。
    public let bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// 从图像里认字。
///
/// 抽成协议是为了测试：真机上的 Vision 需要真实文字才认得出来，
/// 用固定结果就能把「文字层怎么放」这件事单独测清楚。
public protocol TextRecognizing: Sendable {
    func lines(in image: CGImage) throws -> [RecognizedLine]
}

/// 用系统 Vision 在本机识别，图片不出这台机器。
public struct VisionTextRecognizer: TextRecognizing {

    /// 识别语言；留空表示交给 Vision 按系统语言自选。
    public let languages: [String]

    public init(languages: [String] = []) {
        self.languages = languages
    }

    public func lines(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, bounds: observation.boundingBox)
        }
    }
}

/// 图片 → 纯文本。
///
/// 与 PDF 那条路的区别：这里没有「已有的文字层」可复用，图片里的字只能靠识别。
/// 动图取第一帧，与项目其它地方对动图的处理保持一致。
public enum ImageTextExporter {

    @discardableResult
    public static func extractText(
        url: URL,
        recognizer: TextRecognizing = VisionTextRecognizer(),
        to outputURL: URL,
        cancellation: CancellationFlag = CancellationFlag()
    ) throws -> (url: URL, lineCount: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ConversionError.unreadableFile()
        }
        if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }

        // 识别失败（例如画面里没有文字）不该让整次转换算失败：产出一个空的 .txt，
        // 并在说明里讲清楚，比报错更有用。
        let lines = (try? recognizer.lines(in: image)) ?? []

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(outputURL)

        let text = lines.map(\.text).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: target, options: .atomic)
        return (target, lines.count)
    }
}
