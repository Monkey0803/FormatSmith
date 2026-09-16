import CoreGraphics
import Foundation

/// 把同一张证件照在相纸上排满，供冲印后剪开。
public enum PhotoSheetTiler {

    /// 排版结果：几行几列、每张的位置与大小。
    public struct Layout: Equatable, Sendable {
        public let columns: Int
        public let rows: Int
        /// 单张照片占用的点尺寸。
        public let cellSize: CGSize
        /// 每张照片在相纸上的位置（点，原点左下）。
        public let cells: [CGRect]

        public var count: Int { cells.count }
    }

    /// 计算排版，所有尺寸单位都是**点**（1 pt = 1/72 inch）。
    ///
    /// 用点而不是像素：排版结果与输出分辨率无关，`render` 再负责点��像素的��算。
    /// 之前这里按像素算、`render` 却按点画，结果整张相纸只印出一张巨型照片。
    ///
    /// 不写死「6 寸能放 8 张」这类经验值：相纸尺寸、照片尺寸、边距、间距都会变，
    /// 直接按能放几张算几张，数量交给界面显示。
    public static func layout(
        photo: IDPhotoSize,
        sheet: PrintSheet,
        marginMM: Double,
        gapMM: Double
    ) -> Layout {
        let unit = IDPhotoSize.pointsPerMillimetre
        let sheetWidth = sheet.widthMM * unit
        let sheetHeight = sheet.heightMM * unit
        let cellWidth = photo.widthMM * unit
        let cellHeight = photo.heightMM * unit

        let margin = max(0, marginMM) * unit
        let gap = max(0, gapMM) * unit

        let usableWidth = sheetWidth - 2 * margin
        let usableHeight = sheetHeight - 2 * margin

        func fitCount(usable: CGFloat, cell: CGFloat) -> Int {
            guard cell > 0, usable >= cell else { return 0 }
            // n 张照片 + (n-1) 个间距
            return max(0, Int(floor((usable + gap) / (cell + gap))))
        }

        let columns = fitCount(usable: usableWidth, cell: cellWidth)
        let rows = fitCount(usable: usableHeight, cell: cellHeight)

        guard columns > 0, rows > 0 else {
            return Layout(columns: 0, rows: 0, cellSize: .zero, cells: [])
        }

        let usedWidth = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap
        let usedHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap
        // 在相纸上居中，冲印店裁切时留白均匀
        let originX = (sheetWidth - usedWidth) / 2
        let originY = (sheetHeight - usedHeight) / 2

        var cells: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(
                    CGRect(
                        x: originX + CGFloat(column) * (cellWidth + gap),
                        y: originY + CGFloat(row) * (cellHeight + gap),
                        width: cellWidth,
                        height: cellHeight
                    )
                )
            }
        }

        return Layout(
            columns: columns,
            rows: rows,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            cells: cells
        )
    }

    /// 渲染整张相纸。
    ///
    /// - Parameter cutGuides: 画一圈很淡的裁切辅助线，剪的时候有参照；不想要就关掉。
    public static func render(
        photo: CGImage,
        photoSize: IDPhotoSize,
        sheet: PrintSheet,
        dpi: Double,
        marginMM: Double = 2,
        gapMM: Double = 1,
        cutGuides: Bool = true
    ) throws -> CGImage {
        let plan = layout(photo: photoSize, sheet: sheet, marginMM: marginMM, gapMM: gapMM)
        guard plan.count > 0 else {
            throw ConversionError(
                Localized.text("This photo does not fit on the selected paper.")
            )
        }

        let sheetPixels = sheet.pixelSize(dpi: dpi)
        let context = try BitmapContext.make(
            width: sheetPixels.width,
            height: sheetPixels.height,
            wantsAlpha: false
        )
        // 相纸是白的
        context.fill(with: .white)

        // 版面是点，画布是像素：这里做唯一的单位换算
        let scale = CGFloat(sheetPixels.width) / (CGFloat(sheet.widthMM) * IDPhotoSize.pointsPerMillimetre)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high

        for cell in plan.cells {
            context.draw(photo, in: cell)
            if cutGuides {
                context.setStrokeColor(CGColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1))
                context.setLineWidth(0.2 * IDPhotoSize.pointsPerMillimetre)
                context.stroke(cell)
            }
        }
        context.restoreGState()

        guard let result = context.makeImage() else {
            throw ConversionError(Localized.text("Rendering failed."))
        }
        return result
    }
}
