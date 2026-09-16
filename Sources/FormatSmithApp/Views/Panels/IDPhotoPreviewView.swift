import AppKit
import FormatSmithCore
import SwiftUI

/// 证件照预览：直接展示处理管线跑出来的结果。
///
/// 换底色、按人脸构图这些效果没法用文字描述，只能看。
/// 这里显示的就是导出时会得到的图，尺寸也和导出完全一致。
struct IDPhotoPreviewView: View {
    let preview: IDPhotoPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let photo = preview.photo {
                    PreviewTile(
                        image: photo,
                        caption: Localized.text("Result"),
                        height: 150
                    )
                }
                if let sheet = preview.sheet {
                    PreviewTile(
                        image: sheet,
                        caption: preview.caption,
                        height: 150
                    )
                }
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

            ForEach(preview.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preview.photo != nil, preview.sheet == nil, !preview.caption.isEmpty {
                Text(preview.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 单张预览图：点击可以放大看。
private struct PreviewTile: View {
    let image: NSImage
    let caption: String
    let height: CGFloat

    @State private var isEnlarged = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
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
                            .frame(maxWidth: 420, maxHeight: 520)
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
