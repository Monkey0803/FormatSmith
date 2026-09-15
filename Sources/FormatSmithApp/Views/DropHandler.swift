import AppKit
import Foundation
import UniformTypeIdentifiers

/// 把 Finder / 其他 App 拖来的内容解析成本地文件 URL。
///
/// 用 `loadDataRepresentation` / `loadInPlaceFileRepresentation`（macOS 11+ 的现代 API），
/// 而不是已弃用的 `loadItem`，并且同时支持「真实文件」和「文件承诺」两种来源。
enum DropHandler {

    static func handle(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []
        var accepted = false

        func append(_ url: URL) {
            guard url.isFileURL else { return }
            lock.lock()
            collected.append(url)
            lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data, let url = decodeFileURL(from: data) else { return }
                    append(url)
                }
            } else if let supported = firstSupportedContentType(of: provider) {
                // 某些 App 只提供文件承诺，不提供 file URL。
                accepted = true
                group.enter()
                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: supported) { url, _, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    append(url)
                }
            }
        }

        guard accepted else { return false }
        group.notify(queue: .main) { completion(collected) }
        return true
    }

    /// `public.file-url` 的数据可能是 UTF-8 的 URL 字符串，也可能是 URL 的归档表示。
    static func decodeFileURL(from data: Data) -> URL? {
        if let string = String(data: data, encoding: .utf8),
            string.hasPrefix("file:"),
            let url = URL(string: string),
            url.isFileURL
        {
            return url
        }
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            return url
        }
        return nil
    }

    private static let promisedTypes = [
        UTType.pdf.identifier,
        UTType.image.identifier,
        UTType.plainText.identifier,
        UTType.html.identifier,
        "org.openxmlformats.wordprocessingml.document",
    ]

    private static func firstSupportedContentType(of provider: NSItemProvider) -> String? {
        promisedTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }
}
