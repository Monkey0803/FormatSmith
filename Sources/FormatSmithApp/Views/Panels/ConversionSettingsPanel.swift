import AppKit
import FormatSmithCore
import SwiftUI

/// 右侧设置面板。
struct ConversionSettingsPanel: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                formatSection
                qualitySection
                resolutionSection
                backgroundSection
                pageRangeSection
                outputSection
                previewSection
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        // 转换进行中锁定设置：本次转换使用开始时的快照，避免改动造成误解。
        .disabled(model.isConverting)
    }

    /// 当前可选格式；若已选格式不在精选列表里（例如上次选了长尾格式），补进去避免选择器空白。
    private var formatOptions: [ImageFormat] {
        var options = model.availableFormats
        if !options.contains(model.settings.format) {
            options.insert(model.settings.format, at: 0)
        }
        return options
    }

    // MARK: 格式

    private var formatSection: some View {
        SettingsCard(title: Localized.text("Image format"), systemImage: "photo.on.rectangle.angled") {
            Picker(
                "",
                selection: Binding(
                    get: { model.settings.format },
                    set: { newValue in
                        model.settings.format = newValue
                        model.settings.normalizeForFormat()
                    }
                )
            ) {
                ForEach(formatOptions) { format in
                    Text(format.menuLabel).tag(format)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(model.settings.format.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle(
                Localized.text("Show all formats"),
                isOn: Binding(
                    get: { model.showsAllFormats },
                    set: { model.showsAllFormats = $0 }
                )
            )
            .font(.system(size: 11))
            .toggleStyle(.checkbox)

            if let readOnly = FormatRegistry.readOnlyNotable.first {
                Text(
                    Localized.text(
                        "%@ can be opened but not written by macOS, so it is not offered as an output.",
                        readOnly.displayName)
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 画质

    private var qualitySection: some View {
        SettingsCard(title: Localized.text("Quality"), systemImage: "dial.medium") {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { model.settings.quality },
                        set: { model.settings.quality = $0 }
                    ),
                    in: 0.1...1.0
                )
                .disabled(!model.settings.format.supportsQuality)

                Text("\(Int((model.settings.quality * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                    .foregroundStyle(model.settings.format.supportsQuality ? .primary : .tertiary)
            }
            if !model.settings.format.supportsQuality {
                Text(
                    Localized.text(
                        "%@ is lossless, so the quality setting does not apply.",
                        model.settings.format.displayName)
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 分辨率

    private var resolutionSection: some View {
        SettingsCard(title: Localized.text("Resolution"), systemImage: "arrow.up.left.and.arrow.down.right") {
            Picker(
                "",
                selection: Binding(
                    get: { model.settings.resolutionMode },
                    set: { model.settings.resolutionMode = $0 }
                )
            ) {
                ForEach(ResolutionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if model.settings.resolutionMode == .dpi {
                PresetChipRow(
                    values: [72, 150, 200, 300, 600],
                    selected: model.settings.dpi,
                    label: { "\(Int($0))" }
                ) { model.settings.dpi = $0 }

                HStack(spacing: 8) {
                    Text("DPI")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: Binding(
                            get: { model.settings.dpi },
                            set: { model.settings.dpi = min(max($0, 18), 2400) }
                        ), format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    Text(Localized.text("72–150 screen · 300 print · 600 archival"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                PresetChipRow(
                    values: [1, 2, 3, 4],
                    selected: model.settings.scale,
                    label: { "\(Int($0))×" }
                ) { model.settings.scale = $0 }
            }
        }
    }

    // MARK: 背景

    private var backgroundSection: some View {
        SettingsCard(title: Localized.text("Background"), systemImage: "square.on.square") {
            Picker(
                "",
                selection: Binding(
                    get: { model.settings.background },
                    set: { model.settings.background = $0 }
                )
            ) {
                ForEach(ImageBackground.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!model.settings.format.supportsAlpha)

            if !model.settings.format.supportsAlpha {
                Text(
                    Localized.text(
                        "%@ cannot store transparency, so a solid background is used.",
                        model.settings.format.displayName)
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 页码范围

    private var pageRangeSection: some View {
        SettingsCard(title: Localized.text("Pages"), systemImage: "doc.on.doc") {
            Picker(
                "",
                selection: Binding(
                    get: { model.settings.pageRangeMode },
                    set: { model.settings.pageRangeMode = $0 }
                )
            ) {
                ForEach(PageRangeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if model.settings.pageRangeMode == .custom {
                TextField(
                    Localized.text("e.g. 1-3,5,8-10"),
                    text: Binding(
                        get: { model.settings.pageRangeText },
                        set: { model.settings.pageRangeText = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                if !PageRangeParser.validate(model.settings.pageRangeText, pageCount: referencePageCount) {
                    Label(Localized.text("No page matches this range."), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text(Localized.text("One image per page, numbered from 1."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 输出

    private var outputSection: some View {
        SettingsCard(title: Localized.text("Output"), systemImage: "folder") {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12))
                Text(model.settings.resolvedOutputDirectory.path)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.settings.resolvedOutputDirectory.path)
                Spacer(minLength: 4)
            }

            HStack(spacing: 6) {
                Button(Localized.text("Change…")) { model.chooseOutputDirectory() }
                    .controlSize(.small)
                Button(Localized.text("Use Desktop")) { model.resetOutputDirectory() }
                    .controlSize(.small)
                    .disabled(model.settings.outputDirectoryPath.isEmpty)
                Button(Localized.text("Open")) { model.openOutputFolder() }
                    .controlSize(.small)
            }

            Divider().padding(.vertical, 2)

            Toggle(
                Localized.text("Subfolder per source file"),
                isOn: Binding(
                    get: { model.settings.perFileSubfolder },
                    set: { model.settings.perFileSubfolder = $0 }
                )
            )
            .font(.system(size: 12))

            HStack(spacing: 8) {
                Text(Localized.text("File name"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(
                    "{name}-{page}",
                    text: Binding(
                        get: { model.settings.filenamePattern },
                        set: { model.settings.filenamePattern = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }
            Text(Localized.text("Placeholders: {name} {page} {total} {date} {time}"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Toggle(
                Localized.text("Zero-pad page numbers (1 → 001)"),
                isOn: Binding(
                    get: { model.settings.padsPageNumbers },
                    set: { model.settings.padsPageNumbers = $0 }
                )
            )
            .font(.system(size: 12))

            Toggle(
                Localized.text("Open output folder when finished"),
                isOn: Binding(
                    get: { model.settings.openFolderWhenFinished },
                    set: { model.settings.openFolderWhenFinished = $0 }
                )
            )
            .font(.system(size: 12))
        }
    }

    // MARK: 预估

    private var previewSection: some View {
        SettingsCard(title: Localized.text("Preview"), systemImage: "eye") {
            if let first = model.items.first(where: { $0.document.size.width > 0 }) {
                let size = first.document.size
                let scale = model.settings.effectiveScale
                let width = Int((size.width * scale).rounded())
                let height = Int((size.height * scale).rounded())
                let pages = model.settings.pages(outOf: first.document.pageCount).count

                VStack(alignment: .leading, spacing: 5) {
                    previewRow(Localized.text("Each image"), "\(width) × \(height) px")
                    previewRow(
                        Localized.text("First file"),
                        Localized.text("%d image(s) · %@", pages, model.settings.format.displayName)
                    )
                    previewRow(
                        Localized.text("Example name"),
                        OutputNaming.fileName(
                            for: first.name,
                            page: 1,
                            pageCount: max(first.document.pageCount, 1),
                            settings: model.settings
                        ),
                        monospaced: true
                    )
                    if Double(width * height) > Double(model.settings.maxPixels) {
                        Label(
                            Localized.text("This resolution is over the safety limit and will be rejected."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    }
                }
            } else {
                Text(Localized.text("Add a file to see the estimated output."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var referencePageCount: Int {
        model.items.first?.document.pageCount ?? 0
    }

    @ViewBuilder
    private func previewRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 可复用组件

/// 一排等宽的预设按钮（DPI / 倍数）。
struct PresetChipRow: View {
    let values: [Double]
    let selected: Double
    let label: (Double) -> String
    let onSelect: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                let isSelected = abs(selected - value) < 0.01
                Button {
                    onSelect(value)
                } label: {
                    Text(label(value))
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
        }
    }
}

/// 设置面板里的分组卡片。
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}
