import FormatSmithCore
import SwiftUI

/// 一轮转换之后的汇总：成功了几个、哪几个失败、为什么。
///
/// 批量转换里失败往往只是个例（路径没权限、缺 LibreOffice），
/// 与其让用户一个个点开看，不如把原因摊开，并且能只重跑失败的那几个。
struct BatchSummaryCard: View {
    @ObservedObject var model: ConverterModel

    @State private var showsAllFailures = false

    private var summary: BatchSummary { model.batchSummary ?? BatchSummary() }

    var body: some View {
        SettingsCard(title: Localized.text("Result"), systemImage: "checklist") {
            HStack(spacing: 12) {
                if summary.succeeded > 0 {
                    Label(
                        Localized.text("%d succeeded", summary.succeeded),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                }
                if summary.hasFailures {
                    Label(
                        Localized.text("%d failed", summary.failures.count),
                        systemImage: "xmark.circle.fill"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                }
                if summary.cancelled {
                    Label(Localized.text("Cancelled"), systemImage: "stop.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }

            if summary.outputCount > 0 {
                Text(Localized.text("%d file(s) written", summary.outputCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if summary.hasFailures {
                Divider().padding(.vertical, 2)
                failureList
            }

            HStack(spacing: 8) {
                if summary.hasFailures {
                    Button {
                        model.retryFailedItems()
                    } label: {
                        Label(Localized.text("Retry failed"), systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .disabled(model.isConverting)
                }
                if summary.outputFolder != nil {
                    Button {
                        model.openOutputFolder()
                    } label: {
                        Label(Localized.text("Open output folder"), systemImage: "folder")
                            .font(.system(size: 11))
                    }
                }
                Spacer(minLength: 4)
                Button {
                    model.dismissBatchSummary()
                } label: {
                    Text(Localized.text("Dismiss"))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var failureList: some View {
        let shown = showsAllFailures ? summary.failures : Array(summary.failures.prefix(3))

        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { failure in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if summary.failures.count > 3 {
            Button {
                showsAllFailures.toggle()
            } label: {
                Text(
                    showsAllFailures
                        ? Localized.text("Show fewer")
                        : Localized.text("Show all %d", summary.failures.count)
                )
                .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
