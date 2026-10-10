import AppKit
import FormatSmithCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                QueueListView()
                    .frame(minWidth: 400, idealWidth: 540)
                ConversionSettingsPanel()
                    .frame(minWidth: 340, idealWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BottomBarView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DropHandler.handle(providers) { urls in
                model.add(urls: urls)
            }
        }
        .localizedText(model.language)
        .sheet(isPresented: $model.showsAbout) {
            AboutView()
        }
    }
}

// MARK: - 底部操作栏

struct BottomBarView: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isConverting {
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(height: 4)
            }
            // 误点 × 之后还有退路。只保留最近一次，撤销不该是一件需要想的事。
            if let removed = model.recentlyRemoved, !model.isConverting {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                    Text(Localized.text("Removed %d file(s)", removed.entries.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(Localized.text("Undo")) { model.undoRemove() }
                        .font(.system(size: 12))
                        .keyboardShortcut("z", modifiers: .command)
                    Spacer(minLength: 4)
                    Button {
                        model.dismissUndoOffer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Localized.text("Dismiss"))
                    .accessibilityLabel(Localized.text("Dismiss"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 13))
                Text(model.status.resolved())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)

                if model.isConverting {
                    Text("\(Int(model.overallProgress * 100))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(Localized.text("Cancel")) { model.cancelConversion() }
                        .controlSize(.large)
                } else {
                    Button(Localized.text("Open Output Folder")) { model.openOutputFolder() }
                        .controlSize(.large)
                    Button {
                        model.startConversion()
                    } label: {
                        Label(model.actionTitle, systemImage: "wand.and.sparkles")
                            .frame(minWidth: 92)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConvert)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .localizedText(model.language)
    }

    private var statusIcon: String {
        if model.isConverting { return "arrow.triangle.2.circlepath" }
        if model.status.isSuccess { return "checkmark.circle.fill" }
        return "info.circle"
    }

    private var statusColor: Color {
        if model.isConverting { return .accentColor }
        if model.status.isSuccess { return .green }
        return .secondary
    }
}
