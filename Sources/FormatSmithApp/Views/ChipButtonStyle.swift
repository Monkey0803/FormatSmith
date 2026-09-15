import SwiftUI

/// 「整格可点」的芯片按钮样式。
///
/// 为什么需要它：用 `.buttonStyle(.plain)` 时，命中区域是标签**实际画出来的内容**，
/// 而不是 `.frame(maxWidth: .infinity)` 撑出来的范围。撑出来的透明区域默认不参与命中测试，
/// 于是只有图标和文字那一小块能点中——表现就是「点格子空白处没反应」。
/// 必须在标签上显式声明 `contentShape`，把整格纳入命中区域。
///
/// 顺带补上悬停与按下的反馈：命中区域变大之后，用户也需要看得出哪里可以点。
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var verticalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        ChipButtonLabel(
            configuration: configuration,
            isSelected: isSelected,
            verticalPadding: verticalPadding,
            cornerRadius: cornerRadius
        )
    }
}

private struct ChipButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var fill: Color {
        if isSelected {
            return Color.accentColor.opacity(configuration.isPressed ? 0.65 : 0.85)
        }
        if configuration.isPressed { return Color.secondary.opacity(0.30) }
        if isHovering { return Color.secondary.opacity(0.20) }
        return Color.secondary.opacity(0.12)
    }

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            // 关键：用 Rectangle 而不是圆角形状，四个角也照收，
            // 命中判定尽量宽容一点，多点几像素不算错。
            .contentShape(Rectangle())
            .background(shape.fill(fill))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
