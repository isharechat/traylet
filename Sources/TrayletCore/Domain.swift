import Foundation
import ImageIO

/// One immutable PNG crossing capture, editing, OCR and clipboard interfaces.
public struct RasterImage: Equatable, Sendable {
    public let pngData: Data
    public let width: Int
    public let height: Int

    public init(pngData: Data) throws {
        guard !pngData.isEmpty, pngData.count <= 128 * 1_024 * 1_024,
              pngData.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(pngData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height else {
            throw FeatureIssue.invalidInput("图片无效或超过安全尺寸。")
        }
        self.pngData = pngData
        self.width = width
        self.height = height
    }
}

public enum TranslationEngineChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, ai, deepl, google, myMemory
    public var id: String { rawValue }
    /// Files written while the self-hosted DLX engine existed name it "dlx"; it no longer exists, so they fall back to system translation.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .system
    }
}

public enum FeatureIssue: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidInput(String)
    case unavailable(String)
    case permission(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "已取消。"
        case .invalidInput(let message), .unavailable(let message), .permission(let message), .storage(let message): message
        }
    }
}
