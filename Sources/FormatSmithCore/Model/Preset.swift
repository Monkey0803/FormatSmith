import Foundation

/// 一键套用的参数组合。
///
/// 预设刻意都用 `resolutionMode = .dpi`：对 PDF 是真正的 DPI，对图片则是
/// 「72 DPI = 原始像素」的换算，所以同一个预设对两种输入都成立。
public struct Preset: Identifiable, Sendable {
    public let id: String
    /// 名字与说明存的是**英文原文（也就是翻译表的 key）**，读取时才解析。
    ///
    /// 之前这里存的是 `Localized.text("Web")` 的结果 —— 而 `PresetLibrary.all` 是
    /// `static let`，只会构造一次，于是预设名在第一次取用时就把语言定死了：
    /// 界面其它地方都跟着切成了中文，预设框里还是英文。
    let nameKey: String
    let detailKey: String

    public var name: String { Localized.text(nameKey) }
    public var detail: String { Localized.text(detailKey) }
    public let systemImage: String
    /// 这个预设显式声明的改动。没声明的项由 `apply(to:)` 负责回到默认值。
    let mutations: @Sendable (inout ConversionSettings) -> Void

    /// 应用预设：以**默认设置**为底，只叠上预设自己声明的项。
    ///
    /// 这一点很要紧。以前是在当前设置上「打补丁」，预设没提到的项保持原样，
    /// 于是上一次选的证件照（蓝底）会残留在下一次「打印」预设里 ——
    /// 用户点的是「打印」，拿到的却是一块蓝色。
    /// 预设是一份完整的配方，点下去就该得到确定的结果，
    /// 而且这样以后新增设置项也不会漏掉清理。
    ///
    /// 只保留与「输出到哪、怎么写」有关的个人偏好：这些不属于任何预设。
    public func apply(to settings: inout ConversionSettings) {
        let current = settings
        var fresh = ConversionSettings()
        fresh.outputDirectoryPath = current.outputDirectoryPath
        fresh.perFileSubfolder = current.perFileSubfolder
        fresh.filenamePattern = current.filenamePattern
        fresh.padsPageNumbers = current.padsPageNumbers
        fresh.openFolderWhenFinished = current.openFolderWhenFinished
        fresh.maxPixels = current.maxPixels
        fresh.maxConcurrentFiles = current.maxConcurrentFiles

        mutations(&fresh)
        fresh.normalizeForFormat()
        settings = fresh
    }

    /// 返回应用后的设置，不修改原值。
    public func applied(to current: ConversionSettings) -> ConversionSettings {
        var copy = current
        apply(to: &copy)
        return copy
    }
}

public enum PresetLibrary {

    public static let all: [Preset] = [
        Preset(
            id: "web",
            nameKey: "Web",
            // 144 DPI = 2 倍，正好是常见的高分屏尺寸
            detailKey: "PNG at 2× — crisp on Retina screens",
            systemImage: "globe"
        ) { settings in
            settings.target = .image(.png)
            settings.resolutionMode = .dpi
            settings.dpi = 144
            // 图片看的是 scale，PDF 看的是 dpi —— 两条都要交代清楚
            settings.scale = 2
            // 高分屏够用即可，别把 48MP 原图原样端上去
            settings.maxLongEdge = 2048
            settings.background = .transparent
        },

        Preset(
            id: "email",
            nameKey: "Email",
            detailKey: "JPEG, small enough to attach",
            systemImage: "envelope"
        ) { settings in
            settings.target = .image(.jpeg)
            settings.resolutionMode = .dpi
            settings.dpi = 120
            settings.scale = 1
            // 「小到能当附件」以前只换了格式，尺寸一个像素没动
            settings.maxLongEdge = 1600
            settings.quality = 0.75
            settings.background = .white
        },

        Preset(
            id: "print",
            nameKey: "Print",
            detailKey: "TIFF at 300 DPI, lossless",
            systemImage: "printer"
        ) { settings in
            settings.target = .image(.tiff)
            settings.resolutionMode = .dpi
            settings.dpi = 300
            settings.scale = 1
            settings.maxLongEdge = 0
            settings.background = .white
        },

        Preset(
            id: "archive",
            nameKey: "Archive",
            detailKey: "PNG at original size, nothing thrown away",
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
            nameKey: "ID photo",
            detailKey: "1-inch photo, blue background, 300 DPI",
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
            nameKey: "Photo sheet",
            detailKey: "Fill a 6-inch sheet with 1-inch photos, ready to print",
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
            nameKey: "ID scan",
            detailKey: "Front and back of an ID on one A4 page",
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
            id: "imagesToPDF",
            nameKey: "Images to PDF",
            detailKey: "One PDF, one page per image, at original size",
            systemImage: "doc.richtext"
        ) { settings in
            settings.target = .pdf
            settings.pdfLayout = .onePerPage
            settings.pdfPageSize = .fitImage
            settings.mergeImagesIntoOnePDF = true
            settings.pdfCompressesImages = true
            settings.pdfImageQuality = 0.85
        },

        Preset(
            id: "pdfToImages",
            nameKey: "PDF to images",
            detailKey: "PNG per page at 150 DPI",
            systemImage: "photo.on.rectangle.angled"
        ) { settings in
            settings.target = .image(.png)
            settings.resolutionMode = .dpi
            settings.dpi = 150
            settings.scale = 1
            settings.background = .white
        },

        Preset(
            id: "scan",
            nameKey: "Scanned PDF",
            detailKey: "All images into one compressed PDF",
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
