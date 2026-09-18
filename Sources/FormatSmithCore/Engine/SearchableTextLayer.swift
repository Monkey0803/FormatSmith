import CoreGraphics
import CoreText
import Foundation

/// 把识别出的文字铺成 PDF 的**透明文字层**。
///
/// 扫描件只有像素，搜不了也选不中。扫描一遍之后在图片上叠一层看不见的文字，
/// 文件就变成「可搜索 PDF」：肉眼看到的还是原来的扫描样子，搜索、复制、选中的却是真文字。
///
/// 文字用全透明绘制：视觉上不可见，但仍在页面内容流里，所以照样可搜索。
public enum SearchableTextLayer {

    /// 把文字层画到当前页面上。
    ///
    /// - Parameter box: 页面尺寸（点）。归一化的识别结果会映射到这里。
    public static func draw(
        lines: [RecognizedLine],
        in context: CGContext,
        box: CGRect
    ) {
        for line in lines {
            draw(line, in: context, box: box)
        }
    }

    private static func draw(_ line: RecognizedLine, in context: CGContext, box: CGRect) {
        let rect = CGRect(
            x: box.minX + line.bounds.minX * box.width,
            y: box.minY + line.bounds.minY * box.height,
            width: line.bounds.width * box.width,
            height: line.bounds.height * box.height
        )
        guard rect.width > 0, rect.height > 0 else { return }

        // 字号先按行高给一个，再按行宽收一收：
        // 文字层虽然看不见，但它决定了搜索命中时的选区大小，贴合一点更好用。
        var size = max(rect.height * 0.85, 1)
        var textLine = makeLine(line.text, size: size)
        let measured = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
        if measured > 0, measured > rect.width {
            size = max(size * (rect.width / measured), 1)
            textLine = makeLine(line.text, size: size)
        }

        context.saveGState()
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }

    private static func makeLine(_ text: String, size: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, size, nil),
            // 全透明：看得见的是底下的扫描图，文字只留给搜索与选中
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 0),
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
    }

    /// 这一页有没有值得写进文字层的文字。
    public static func hasText(_ lines: [RecognizedLine]) -> Bool {
        !lines.isEmpty
    }
}
