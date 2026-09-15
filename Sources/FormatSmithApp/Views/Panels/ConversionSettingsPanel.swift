import AppKit
import FormatSmithCore
import SwiftUI

/// 右侧设置面板。内容随「输出目标」变化：选图片格式时给图片参数，选 PDF 时给版面参数。
struct ConversionSettingsPanel: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                presetSection
                targetSection
                if !model.missingRequiredTools.isEmpty {
                    dependencySection
                }
                if model.target.isPDF {
                    if model.hasPDFInputs {
                        pdfToolSection
                    }
                    if model.hasImageInputs {
                        pdfLayoutSection
                        pdfCompressionSection
                    }
                } else {
                    qualitySection
                    resolutionSection
                    backgroundSection
                }
                if showPageRangeSection {
                    pageRangeSection
                }
                outputSection
                previewSection
                languageSection
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        // 转换进行中锁定设置：本次转换使用开始时的快照，避免改动造成误解。
        .disabled(model.isConverting)
    }

    /// 当前可选格式；若已选格式不在当前列表里（例如上次选了长尾格式），补进去避免选择器空白。
    private var formatOptions: [ImageFormat] {
        var options = model.availableFormats
        if let current = model.target.imageFormat, !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    // MARK: 预设

    private var presetSection: some View {
        SettingsCard(title: Localized.text("Presets"), systemImage: "wand.and.stars") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
                spacing: 6
            ) {
                ForEach(PresetLibrary.all) { preset in
                    let selected = model.matches(preset)
                    Button {
                        model.apply(preset)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.systemImage)
                                .font(.system(size: 13))
                            Text(preset.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .help(preset.detail)
                }
            }

            if let description = PresetLibrary.all.first(where: { model.matches($0) })?.detail {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 输出目标

    private var targetSection: some View {
        SettingsCard(title: Localized.text("Output format"), systemImage: "arrow.right.doc.on.clipboard") {
            Picker(
                "",
                selection: Binding(
                    get: { model.target },
                    set: { model.target = $0 }
                )
            ) {
                SwiftUI.Section(Localized.text("Images")) {
                    ForEach(formatOptions) { format in
                        Text(format.menuLabel).tag(OutputTarget.image(format))
                    }
                }
                SwiftUI.Section(Localized.text("Documents")) {
                    Text("PDF").tag(OutputTarget.pdf)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(targetSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.target.isPDF {
                Toggle(
                    Localized.text("Show all formats"),
                    isOn: Binding(
                        get: { model.showsAllFormats },
                        set: { model.showsAllFormats = $0 }
                    )
                )
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
            }

            if let reason = model.unavailableReasons.first {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 缺少外部工具时给出的说明与安装入口。
    private var dependencySection: some View {
        SettingsCard(title: Localized.text("Missing tools"), systemImage: "wrench.adjustable") {
            ForEach(model.missingRequiredTools, id: \.name) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    Label(tool.name, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)

                    Text(tool.installHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let command = tool.installCommand {
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                                .textSelection(.enabled)
                            Button(Localized.text("Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Text(Localized.text("Everything else works without it."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var targetSummary: String {
        if model.target.isPDF {
            if model.hasPDFInputs {
                return model.settings.pdfTool.summary
            }
            if model.hasImageInputs, model.settings.mergeImagesIntoOnePDF, model.convertibleItems.count > 1 {
                return Localized.text("All images are merged into a single PDF.")
            }
            return Localized.text("One PDF per source file.")
        }
        return model.target.imageFormat?.summary ?? ""
    }

    // MARK: 画质

    private var currentFormatSupportsQuality: Bool {
        model.target.imageFormat?.supportsQuality ?? false
    }

    private var currentFormatSupportsAlpha: Bool {
        model.target.imageFormat?.supportsAlpha ?? false
    }

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
                .disabled(!currentFormatSupportsQuality)

                Text("\(Int((model.settings.quality * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                    .foregroundStyle(currentFormatSupportsQuality ? .primary : .tertiary)
            }
            if !currentFormatSupportsQuality, let format = model.target.imageFormat {
                Text(Localized.text("%@ is lossless, so the quality setting does not apply.", format.displayName))
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
                    Text(
                        model.hasPDFInputs
                            ? Localized.text("72–150 screen · 300 print · 600 archival")
                            : Localized.text("For images, 72 DPI means the original pixel size.")
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                }
            } else {
                PresetChipRow(
                    values: [0.5, 1, 2, 3, 4],
                    selected: model.settings.scale,
                    label: { $0 < 1 ? "\(Int($0 * 100))%" : "\(Int($0))×" }
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
            .disabled(!currentFormatSupportsAlpha)

            if !currentFormatSupportsAlpha, let format = model.target.imageFormat {
                Text(Localized.text("%@ cannot store transparency, so a solid background is used.", format.displayName))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 页码范围在两种情况下有意义：PDF 转图片，以及 PDF 工具箱里的「提取页」。
    private var showPageRangeSection: Bool {
        guard model.hasPDFInputs else { return false }
        if model.target.isPDF {
            return model.settings.pdfTool == .extract
        }
        return true
    }

    // MARK: PDF 工具箱

    private var pdfToolSection: some View {
        SettingsCard(title: Localized.text("PDF tool"), systemImage: "wrench.and.screwdriver") {
            Picker(
                "",
                selection: Binding(
                    get: { model.settings.pdfTool },
                    set: { model.settings.pdfTool = $0 }
                )
            ) {
                ForEach(PDFTool.allCases) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(model.settings.pdfTool.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.settings.pdfTool {
            case .merge:
                if model.convertibleItems.count < 2 {
                    Text(Localized.text("Add at least two PDFs to merge; with one file this just copies it."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .split:
                HStack(spacing: 8) {
                    Text(Localized.text("Pages per file"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: Binding(
                            get: { model.settings.splitEveryPages },
                            set: { model.settings.splitEveryPages = min(max($0, 1), 5000) }
                        ), format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    Spacer()
                }

            case .extract:
                EmptyView()

            case .rotate:
                Picker(
                    "",
                    selection: Binding(
                        get: { model.settings.rotationAngle },
                        set: { model.settings.rotationAngle = $0 }
                    )
                ) {
                    ForEach(RotationAngle.allCases) { angle in
                        Text(angle.displayName).tag(angle)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

            case .compress:
                PresetChipRow(
                    values: [72, 100, 150, 200],
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
                            set: { model.settings.dpi = min(max($0, 18), 600) }
                        ), format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    Spacer()
                }

                Label(
                    Localized.text("Compressing turns each page into an image: text is no longer selectable."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
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

            if model.hasImageInputs {
                Text(Localized.text("Page ranges apply to PDF input only; images are always exported whole."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: PDF 版面

    private var pdfLayoutSection: some View {
        SettingsCard(title: Localized.text("PDF page"), systemImage: "doc.plaintext") {
            if model.hasImageInputs, model.convertibleItems.count > 1 {
                Toggle(
                    Localized.text("Merge all images into one PDF"),
                    isOn: Binding(
                        get: { model.settings.mergeImagesIntoOnePDF },
                        set: { model.settings.mergeImagesIntoOnePDF = $0 }
                    )
                )
                .font(.system(size: 12))
            }

            Picker(
                "",
                selection: Binding(
                    get: { model.settings.pdfPageSize },
                    set: { model.settings.pdfPageSize = $0 }
                )
            ) {
                ForEach(PDFPageSize.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if model.settings.pdfPageSize == .fitImage {
                Text(Localized.text("Each page matches its image: 1 pixel = 1 point."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    Text(Localized.text("Margin"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: Binding(
                            get: { model.settings.pdfMargin },
                            set: { model.settings.pdfMargin = min(max($0, 0), 200) }
                        ), format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    Text(Localized.text("points"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Text(Localized.text("Images are scaled to fit and centered on the page."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var pdfCompressionSection: some View {
        SettingsCard(title: Localized.text("PDF size"), systemImage: "arrow.down.circle") {
            Toggle(
                Localized.text("Compress embedded images (JPEG)"),
                isOn: Binding(
                    get: { model.settings.pdfCompressesImages },
                    set: { model.settings.pdfCompressesImages = $0 }
                )
            )
            .font(.system(size: 12))

            if model.settings.pdfCompressesImages {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { model.settings.pdfImageQuality },
                            set: { model.settings.pdfImageQuality = $0 }
                        ),
                        in: 0.2...1.0
                    )
                    Text("\(Int((model.settings.pdfImageQuality * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
                Text(Localized.text("Photographs shrink a lot; images with transparency are kept lossless."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Localized.text("Images are embedded losslessly, so the PDF can be large."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

            if !model.target.isPDF {
                Toggle(
                    Localized.text("Zero-pad page numbers (1 → 001)"),
                    isOn: Binding(
                        get: { model.settings.padsPageNumbers },
                        set: { model.settings.padsPageNumbers = $0 }
                    )
                )
                .font(.system(size: 12))
            }

            Toggle(
                Localized.text("Open output folder when finished"),
                isOn: Binding(
                    get: { model.settings.openFolderWhenFinished },
                    set: { model.settings.openFolderWhenFinished = $0 }
                )
            )
            .font(.system(size: 12))

            if model.convertibleItems.count > 1 {
                HStack(spacing: 8) {
                    Text(Localized.text("Parallel files"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.settings.maxConcurrentFiles },
                            set: { model.settings.maxConcurrentFiles = $0 }
                        )
                    ) {
                        Text(Localized.text("Auto")).tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: 语言

    private var languageSection: some View {
        SettingsCard(title: Localized.text("Language"), systemImage: "character.bubble") {
            Picker(
                "",
                selection: Binding(
                    get: { model.language },
                    set: { model.language = $0 }
                )
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(Localized.text("Switches immediately; no restart needed."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 预估

    private var previewSection: some View {
        SettingsCard(title: Localized.text("Preview"), systemImage: "eye") {
            if let first = model.items.first(where: { $0.document.size.width > 0 }) {
                VStack(alignment: .leading, spacing: 5) {
                    if model.target.isPDF, model.hasPDFInputs {
                        previewRow(Localized.text("PDF tool"), model.settings.pdfTool.displayName)
                        previewRow(Localized.text("First file"), pdfToolOutcome())
                        previewRow(Localized.text("Example name"), examplePDFName(for: first), monospaced: true)
                    } else if model.target.isPDF {
                        previewRow(Localized.text("PDF page"), pdfPageDescription(for: first))
                        previewRow(Localized.text("First file"), Localized.text("%d page(s)", pagesForPreview))
                        previewRow(Localized.text("Example name"), examplePDFName(for: first), monospaced: true)
                    } else {
                        let size = first.document.size
                        let scale = effectiveScale(for: first)
                        let width = Int((size.width * scale).rounded())
                        let height = Int((size.height * scale).rounded())
                        previewRow(Localized.text("Each image"), "\(width) × \(height) px")
                        previewRow(
                            Localized.text("First file"),
                            Localized.text(
                                "%d image(s) · %@",
                                pagesForPreview,
                                model.target.imageFormat?.displayName ?? ""
                            )
                        )
                        previewRow(Localized.text("Example name"), exampleImageName(for: first), monospaced: true)

                        if Double(width * height) > Double(model.settings.maxPixels) {
                            Label(
                                Localized.text("This resolution is over the safety limit and will be rejected."),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text(Localized.text("Add a file to see the estimated output."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// PDF 工具会产出什么，用一句话说清楚。
    private func pdfToolOutcome() -> String {
        let pageCount = referencePageCount
        switch model.settings.pdfTool {
        case .merge:
            let total = model.items.reduce(0) { $0 + $1.document.pageCount }
            return Localized.text("%d page(s) → 1 file", total)
        case .split:
            let parts = max(1, Int(ceil(Double(pageCount) / Double(max(1, model.settings.splitEveryPages)))))
            return Localized.text("%d page(s) → %d file(s)", pageCount, parts)
        case .extract:
            let selected = model.settings.pages(outOf: pageCount).count
            return Localized.text("%d of %d page(s)", selected, pageCount)
        case .rotate:
            return Localized.text("%d page(s)", pageCount)
        case .compress:
            return Localized.text("%d page(s) at %d DPI", pageCount, Int(model.settings.dpi))
        }
    }

    private func effectiveScale(for item: QueueItem) -> Double {
        if item.document.kind.isImage, !model.hasPDFInputs {
            return model.settings.imageScale
        }
        return model.settings.effectiveScale
    }

    private var pagesForPreview: Int {
        guard let first = model.items.first(where: { $0.document.pageCount > 0 }) else { return 0 }
        if first.document.kind.isImage {
            return model.convertibleItems.filter { $0.document.kind.isImage }.count
        }
        return model.settings.pages(outOf: first.document.pageCount).count
    }

    private func pdfPageDescription(for item: QueueItem) -> String {
        switch model.settings.pdfPageSize {
        case .fitImage:
            let scale = effectiveScale(for: item)
            let width = Int((item.document.size.width * scale).rounded())
            let height = Int((item.document.size.height * scale).rounded())
            return "\(width) × \(height) pt"
        case .a4:
            return "A4 · \(Int(model.settings.pdfMargin)) pt " + Localized.text("margin")
        case .letter:
            return "Letter · \(Int(model.settings.pdfMargin)) pt " + Localized.text("margin")
        }
    }

    private func exampleImageName(for item: QueueItem) -> String {
        OutputNaming.fileName(
            for: item.name,
            page: 1,
            pageCount: max(item.document.pageCount, 1),
            settings: model.settings
        )
    }

    private func examplePDFName(for item: QueueItem) -> String {
        let base = OutputNaming.expand(
            pattern: model.settings.filenamePattern,
            documentName: item.name,
            page: nil,
            pageCount: model.settings.mergeImagesIntoOnePDF ? model.convertibleItems.count : nil,
            padsPageNumbers: model.settings.padsPageNumbers
        )
        return "\(base).pdf"
    }

    private var referencePageCount: Int {
        model.items.first(where: { $0.document.kind == .pdf })?.document.pageCount ?? 0
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
