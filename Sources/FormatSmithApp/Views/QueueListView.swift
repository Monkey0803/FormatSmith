import AppKit
import FormatSmithCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 左侧：文件队列

struct QueueListView: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                EmptyDropZone()
            } else {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.items) { item in
                            QueueRowView(item: item)
                                .padding(.horizontal, 10)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DropHandler.handle(providers) { urls in model.add(urls: urls) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(Localized.text("Files"))
                .font(.headline)
            Text("\(model.items.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                model.chooseInputFiles()
            } label: {
                Label(Localized.text("Add"), systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(model.isConverting)

            Button {
                model.clearFinished()
            } label: {
                Label(Localized.text("Clear Finished"), systemImage: "checkmark.circle")
            }
            .controlSize(.small)
            .disabled(model.isConverting || !model.items.contains { $0.status.isTerminal })

            Button {
                model.removeAll()
            } label: {
                Label(Localized.text("Clear All"), systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(model.isConverting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 空状态 / 拖放区

struct EmptyDropZone: View {
    @EnvironmentObject private var model: ConverterModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.22),
                                Color.accentColor.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 132, height: 132)
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "doc.richtext")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text(isTargeted ? Localized.text("Release to add") : Localized.text("Drop PDF files here"))
                    .font(.title2.weight(.semibold))
                Text(Localized.text("Multiple files are fine — folders work too, PDFs inside are found automatically."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                model.chooseInputFiles()
            } label: {
                Text(Localized.text("Choose PDFs…"))
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 1.5, dash: [8, 6])
                )
                .padding(16)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            DropHandler.handle(providers) { urls in model.add(urls: urls) }
        }
    }
}

// MARK: - 队列行

struct QueueRowView: View {
    @EnvironmentObject private var model: ConverterModel
    let item: QueueItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            statusBadge
            Button {
                model.remove(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(model.isConverting)
            .help(Localized.text("Remove from list"))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var subtitle: String {
        switch item.status {
        case .loading:
            return Localized.text("Reading…")
        case .ready:
            return Localized.text("%d page(s) · ready", item.document.pageCount)
        case let .converting(done, total):
            return Localized.text("Converting %d of %d", done, total)
        case let .finished(files, _):
            return Localized.text("Done · %d image(s) written", files)
        case let .failed(message):
            return Localized.text("Failed: %@", message)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .loading, .ready:
            Text(Localized.text("Ready"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
        case let .converting(done, total):
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("\(done)/\(total)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
        case .finished:
            Button {
                if case let .finished(_, folder) = item.status, let folder {
                    model.reveal(folder)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(Localized.text("Show in Finder"))
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.16)))
                .foregroundStyle(Color.green)
            }
            .buttonStyle(.plain)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(Localized.text("Conversion failed"))
        }
    }
}
