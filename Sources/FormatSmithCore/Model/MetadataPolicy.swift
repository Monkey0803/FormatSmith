import Foundation

/// 输出文件里保留哪些原始元数据。
public enum MetadataPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 全部保留（相机、时间、地点）
    case keep
    /// 保留相机与拍摄信息，去掉定位
    case stripLocation
    /// 什么元数据都不写
    case stripAll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keep: return Localized.text("Keep everything")
        case .stripLocation: return Localized.text("Remove location")
        case .stripAll: return Localized.text("Remove all metadata")
        }
    }

    public var summary: String {
        switch self {
        case .keep: return Localized.text("Camera, capture time and location are carried over.")
        case .stripLocation: return Localized.text("Keeps camera and time, drops GPS coordinates.")
        case .stripAll: return Localized.text("Writes no camera, time or location information.")
        }
    }
}
