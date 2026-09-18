import AppKit
import FormatSmithCore
import SwiftUI

/// 关于面板。
///
/// 开源项目至少该让用户一眼看到：这是什么、版本多少、代码在哪、文件去了哪。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let repository = URL(string: "https://github.com/Monkey0803/FormatSmith")
    private let releases = URL(string: "https://github.com/Monkey0803/FormatSmith/releases")

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            VStack(spacing: 4) {
                Text("FormatSmith")
                    .font(.title2.weight(.semibold))
                Text(Localized.text("Version %@", Self.version))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text(
                Localized.text(
                    "Every conversion runs on this Mac. Files are never uploaded anywhere."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)

            VStack(spacing: 6) {
                if let repository {
                    Link(Localized.text("Source code on GitHub"), destination: repository)
                }
                if let releases {
                    Link(Localized.text("Release notes and downloads"), destination: releases)
                }
            }
            .font(.system(size: 12))

            Text(Localized.text("MIT licensed. Built with SwiftUI, PDFKit and Vision."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Button(Localized.text("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
