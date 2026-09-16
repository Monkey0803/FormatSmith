import Foundation

/// 一键套用的参数组合。
///
/// 预设刻意都用 `resolutionMode = .dpi`：对 PDF 是真正的 DPI，对图片则是
/// 「72 DPI = 原始像素」的换算，所以同一个预设对两种输入都成立。
public struct Preset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let systemImage: String
    let apply: @Sendable (inout ConversionSettings) -> Void

    public func apply(to settings: inout ConversionSettings) {
        apply(&settings)
        settings.normalizeForFormat()
    }
}

public enum PresetLibrary {

    public static let all: [Preset] = [
        Preset(
            id: "web",
            name: Localized.text("Web"),
            // 144 DPI = 2 倍，正好是常见的高分屏尺寸
            detail: Localized.text("PNG at 2× — crisp on Retina screens"),
            systemImage: "globe"
        ) { settings in
            settings.target = .image(.png)
            settings.resolutionMode = .dpi
            settings.dpi = 144
            // 图片看的是 scale，PDF 看的是 dpi —— 两条都要交代清楚
            settings.scale = 2
            settings.background = .transparent
        },

        Preset(
            id: "email",
            name: Localized.text("Email"),
            detail: Localized.text("JPEG, small enough to attach"),
            systemImage: "envelope"
        ) { settings in
            settings.target = .image(.jpeg)
            settings.resolutionMode = .dpi
            settings.dpi = 120
            settings.scale = 1
            settings.quality = 0.75
            settings.background = .white
        },

        Preset(
            id: "print",
            name: Localized.text("Print"),
            detail: Localized.text("TIFF at 300 DPI, lossless"),
            systemImage: "printer"
        ) { settings in
            settings.target = .image(.tiff)
            settings.resolutionMode = .dpi
            settings.dpi = 300
            settings.scale = 1
            settings.background = .white
        },

        Preset(
            id: "archive",
            name: Localized.text("Archive"),
            detail: Localized.text("PNG at original size, nothing thrown away"),
            systemImage: "archivebox"
        ) { settings in
            settings.target = .image(.png)
            settings.resolutionMode = .dpi
            // 72 DPI 对 PDF 是原始尺寸，对图片是原始像素
            settings.dpi = 72
            settings.scale = 1
            settings.background = .white
        },

        Preset(
            id: "idPhoto",
            name: Localized.text("ID photo"),
            detail: Localized.text("1-inch photo, blue background, 300 DPI"),
            systemImage: "person.crop.rectangle"
        ) { settings in
            settings.target = .image(.jpeg)
            settings.resolutionMode = .dpi
            settings.dpi = 300
            settings.scale = 1
            settings.idPhotoEnabled = true
            settings.idPhotoSize = .oneInch
            settings.idPhotoBackground = .blue
            settings.idPhotoAutoCrop = true
            settings.printSheetEnabled = false
        },

        Preset(
            id: "photoSheet",
            name: Localized.text("Photo sheet"),
            detail: Localized.text("Fill a 6-inch sheet with 1-inch photos, ready to print"),
            systemImage: "square.grid.3x3"
        ) { settings in
            settings.target = .image(.jpeg)
            settings.resolutionMode = .dpi
            settings.dpi = 300
            settings.scale = 1
            settings.idPhotoEnabled = true
            settings.idPhotoSize = .oneInch
            settings.idPhotoBackground = .white
            settings.idPhotoAutoCrop = true
            settings.printSheetEnabled = true
            settings.printSheet = .sixInch
            settings.printSheetCutGuides = true
        },

        Preset(
            id: "idScan",
            name: Localized.text("ID scan"),
            detail: Localized.text("Front and back of an ID on one A4 page"),
            systemImage: "creditcard"
        ) { settings in
            settings.target = .pdf
            settings.pdfLayout = .twoPerPage
            settings.pdfPageSize = .a4
            settings.pdfMargin = 24
            settings.pdfCompressesImages = true
            settings.pdfImageQuality = 0.85
            settings.mergeImagesIntoOnePDF = true
        },

        Preset(
            id: "scan",
            name: Localized.text("Scanned PDF"),
            detail: Localized.text("All images into one compressed PDF"),
            systemImage: "doc.viewfinder"
        ) { settings in
            settings.target = .pdf
            settings.mergeImagesIntoOnePDF = true
            settings.pdfPageSize = .a4
            settings.pdfCompressesImages = true
            settings.pdfImageQuality = 0.75
        },
    ]

    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }
}
