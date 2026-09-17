import AppKit
import FormatSmithCore
import SwiftUI

/// 输出预览：直接展示这条管线跑出来的结果。
///
/// 版面、底色、裁切这些效果没法用文字描述，只能看。这里显示的就是导出时会得到的图，
/// 构图与导出完全一致，只是大图会缩成缩略图——真实尺寸写在说明文字里（不是缩略图的尺寸）。
struct OutputPreviewView: View {
    let preview: OutputPreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = preview.image {
                PreviewTile(
                    image: image,
                    caption: preview.caption,
                    // PDF 页面铺白底，图片铺浅色底以便看出透明区域
                    background: preview.kind == .pdfPage ? Color.white : Color(nsColor: .textBackgroundColor),
                    height: 168
                )
            }

            if preview.isRendering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(Localized.text("Rendering preview…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let failure = preview.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preview.image != nil {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(preview.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 这次会产出多少、多少页——预览只画了第一份，剩下的靠这句话交代。
    private var summary: String {
        if preview.kind == .image {
            return preview.fileCount > 1
                ? Localized.text("%d file(s)", preview.fileCount)
                : Localized.text("One image")
        }
        if preview.pageCount > 1 {
            return Localized.text("%d page(s)", preview.pageCount)
        }
        return Localized.text("One page")
    }
}

/// 单张预览图：点击可以放大看。
private struct PreviewTile: View {
    let image: NSImage
    let caption: String
    let background: Color
    let height: CGFloat

    @State private var isEnlarged = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // 整块可点：透明区域默认不参与命中测试
                .contentShape(Rectangle())
                .onTapGesture { isEnlarged = true }
                .help(Localized.text("Click to enlarge"))
                .popover(isPresented: $isEnlarged, arrowEdge: .trailing) {
                    VStack(spacing: 10) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 460, maxHeight: 560)
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
