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
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 13))
                Text(model.statusText)
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
    }

    private var statusIcon: String {
        if model.isConverting { return "arrow.triangle.2.circlepath" }
        if model.statusText.hasPrefix(Localized.text("Finished")) { return "checkmark.circle.fill" }
        return "info.circle"
    }

    private var statusColor: Color {
        if model.isConverting { return .accentColor }
        if model.statusText.hasPrefix(Localized.text("Finished")) { return .green }
        return .secondary
    }
}
