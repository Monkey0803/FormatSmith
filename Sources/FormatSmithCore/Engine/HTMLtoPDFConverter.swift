import CoreGraphics
import Foundation
import PDFKit
import WebKit

/// 用系统自带的 WebKit 把 HTML 渲染成 PDF。
///
/// 这条路径不依赖任何外部工具，所以 HTML 与 Markdown 在没装 pandoc 的机器上也能用。
///
/// 关于分页方式，这里有一个踩过的坑：
/// `WKWebView.pdf(configuration:)` 会把**整页内容塞进一张 PDF 纸**，长文档不会分页，
/// 得到的是一张几千点高的「纸」。而 `NSPrintOperation` 虽然在真机上可用，
/// 在测试进程里会挂住，等于没法回归验证。
///
/// 最终方案是按页截取：先用 JS 量出每个块级元素的位置，尽量在该元素结束处断页，
/// 再逐页截取拼成一份多页 PDF。既能分页，又能在测试里跑。
public enum HTMLtoPDFConverter {

    /// A4 页面尺寸（点）。
    static let defaultPageSize = CGSize(width: 595.28, height: 841.89)

    /// 页边距（点）。通过 CSS 加在 `body` 上 —— 截取模式下 `@page` 是不生效的。
    static let margin: CGFloat = 56

    /// 页数上限。防止有人丢进来一份超长 HTML 把内存吃光。
    static let maximumPages = 500

    /// 把本地 HTML 文件渲染成多页 A4 PDF。
    @discardableResult
    public static func convert(
        htmlURL: URL,
        to outputURL: URL,
        timeout: TimeInterval = 120
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            throw ConversionError.unreadableFile()
        }

        let data = try MainThreadBridge.run(timeout: timeout) { @MainActor in
            try await render(htmlURL: htmlURL)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(outputURL)
        try data.write(to: target, options: .atomic)
        return target
    }

    // MARK: - 主线程实现

    @MainActor
    private static func render(htmlURL: URL) async throws -> Data {
        let contentWidth = defaultPageSize.width
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: CGSize(width: contentWidth, height: defaultPageSize.height)))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter

        // 允许读取同目录资源（图片、CSS），否则相对路径的引用会全部失败。
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        try await waiter.waitForFinish()

        let contentHeight = try await measuredContentHeight(in: webView)
        // 让整页内容都参与布局，否则只有视口内的部分会被渲染。
        webView.frame = CGRect(
            x: 0, y: 0, width: contentWidth, height: max(contentHeight, defaultPageSize.height))

        let starts = try await pageStarts(in: webView, contentHeight: contentHeight)

        let merged = PDFDocument()
        for start in starts.prefix(maximumPages) {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(
                x: 0,
                y: start,
                width: defaultPageSize.width,
                height: defaultPageSize.height
            )
            let slice = try await webView.pdf(configuration: configuration)
            guard let fragment = PDFDocument(data: slice) else { continue }
            for index in 0..<fragment.pageCount {
                guard let page = fragment.page(at: index) else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }

        guard merged.pageCount > 0 else {
            throw ConversionError(Localized.text("Could not render the page."))
        }
        guard let data = merged.dataRepresentation() else {
            throw ConversionError(Localized.text("Could not render the page."))
        }
        return data
    }

    @MainActor
    private static func measuredContentHeight(in webView: WKWebView) async throws -> CGFloat {
        let script = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
        let value = try? await webView.evaluateJavaScript(script)
        let height = CGFloat((value as? NSNumber)?.doubleValue ?? 0)
        return height.isFinite && height > 0 ? height : defaultPageSize.height
    }

    /// 计算每一页的起始偏移。
    ///
    /// 优先在块级元素的结束处断页；如果一页之内一个边界都找不到（例如单个超高代码块），
    /// 就只能硬切 —— 这是截取式分页无法避免的情况。
    @MainActor
    private static func pageStarts(in webView: WKWebView, contentHeight: CGFloat) async throws -> [CGFloat] {
        let pageHeight = defaultPageSize.height
        let script = """
            (function () {
              const pageHeight = \(pageHeight);
              const total = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
              const nodes = Array.from(document.body.querySelectorAll(
                'p,h1,h2,h3,h4,h5,h6,li,pre,blockquote,table,hr,div,section,article'));
              const bottoms = nodes
                .map(function (node) { return node.getBoundingClientRect().bottom + window.scrollY; })
                .filter(function (value) { return isFinite(value) && value > 0; })
                .sort(function (a, b) { return a - b; });

              const starts = [];
              let cursor = 0;
              let guardCount = 0;
              while (cursor < total && guardCount < \(maximumPages)) {
                guardCount += 1;
                const limit = cursor + pageHeight;
                let next = limit;
                for (let i = 0; i < bottoms.length; i++) {
                  const bottom = bottoms[i];
                  if (bottom > cursor && bottom <= limit) { next = bottom; }
                }
                starts.push(cursor);
                cursor = next <= cursor ? cursor + pageHeight : next;
              }
              return starts;
            })()
            """

        if let value = try? await webView.evaluateJavaScript(script) as? [NSNumber] {
            let starts = value.map { CGFloat($0.doubleValue) }
            if !starts.isEmpty { return starts }
        }

        // JS 不可用时的兜底：等距硬切。
        let pageCount = max(1, Int(ceil(contentHeight / pageHeight)))
        return (0..<pageCount).map { CGFloat($0) * pageHeight }
    }

    /// 等待 `loadFileURL` 结束。
    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        private var failure: Error?

        func waitForFinish() async throws {
            if let failure { throw failure }
            if finished { return }
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        private func complete() {
            guard !finished else { return }
            finished = true
            if let continuation {
                self.continuation = nil
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failure = ConversionError(Localized.text("Could not render the page: %@", error.localizedDescription))
            complete()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failure = ConversionError(Localized.text("Could not render the page: %@", error.localizedDescription))
            complete()
        }
    }
}
