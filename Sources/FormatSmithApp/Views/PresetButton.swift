import FormatSmithCore
import SwiftUI

/// 预设格子里的一格。
///
/// 单独成类型有两个原因：设置面板已经很长了；以及「整格都能点」这件事需要能被测试覆盖
/// —— 之前只有图标和文字能点，用户点格子空白处没有任何反应。
struct PresetButton: View {
    let preset: Preset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 13))
                Text(preset.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ChipButtonStyle(isSelected: isSelected))
        .help(preset.detail)
    }
}
