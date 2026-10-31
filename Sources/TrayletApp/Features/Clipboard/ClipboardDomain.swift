import Foundation
import CryptoKit
import ImageIO

struct ClipboardContent: Codable, Equatable, Sendable {
    var representations: [String: Data]
    static let textType = "public.utf8-plain-text"
    static let allowed = Set([textType, "public.rtf", "public.html", "public.png", "public.tiff", "public.jpeg"])
    static func text(_ value: String) -> Self { Self(representations: [textType: Data(value.utf8)]) }
    var plainText: String? { representations[Self.textType].flatMap { String(data: $0, encoding: .utf8) } }
    var byteCount: Int { representations.values.reduce(0) { $0 + $1.count } }
    var imageData: Data? { ["public.png", "public.tiff", "public.jpeg"].compactMap { representations[$0] }.first }
    var valid: Bool {
        guard !representations.isEmpty, Set(representations.keys).isSubset(of: Self.allowed), byteCount <= ClipboardPolicy.itemBytes else { return false }
        let images = representations.filter { ["public.png", "public.tiff", "public.jpeg"].contains($0.key) }
        guard plainText?.isEmpty == false || !images.isEmpty else { return false }
        if let text = representations[Self.textType], String(data: text, encoding: .utf8) == nil { return false }
        return images.allSatisfy { type, data in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == type,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= ClipboardPolicy.imagePixels / h else { return false }
            return true
        }
    }
}

enum ClipboardCopyFormat { case original, plainText }

enum ClipboardPolicy {
    static let itemBytes = 4 * 1_024 * 1_024
    static let totalBytes = 32 * 1_024 * 1_024
    static let imagePixels = 16_000_000
    static func valid(_ items: [ClipboardContent]) -> Bool {
        !items.isEmpty && items.count <= 16 && items.allSatisfy(\.valid) && items.reduce(0, { $0 + $1.byteCount }) <= itemBytes
    }
    static func digest(_ items: [ClipboardContent]) -> String {
        var hash = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for item in items {
            append(Data("item".utf8))
            for key in item.representations.keys.sorted() { append(Data(key.utf8)); append(item.representations[key]!) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let digest: String
    let items: [ClipboardContent]
    var capturedAt: Date
    var favorite: Bool
    var application: String
    var plainText: String? { items.compactMap(\.plainText).joined(separator: "\n").nilIfEmpty }
    var byteCount: Int { items.reduce(0) { $0 + $1.byteCount } }
    var imageData: Data? { items.compactMap(\.imageData).first }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

enum ClipboardKind {
    case text, link, image
    var symbol: String { switch self { case .text: "text.alignleft"; case .link: "link"; case .image: "photo" } }
}

/// What the list shows for an entry, computed once instead of decoding the body on every render.
struct ClipboardDisplay {
    let kind: ClipboardKind
    /// Full plain text for search and preview; empty for images.
    let text: String
    /// One line of at most 200 characters for the row.
    let line: String?
    init(_ entry: ClipboardEntry) {
        let text = entry.plainText ?? ""
        self.text = text
        line = text.isEmpty ? nil : String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        if entry.imageData != nil { kind = .image; return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normal text usually has a space near the start. Reject it before walking every grapheme
        // just to measure a long body that cannot be a standalone URL.
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), trimmed.count < 2048, let url = URL(string: trimmed),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { kind = .link } else { kind = .text }
    }
}

struct ClipboardSettings: Codable, Equatable, Sendable {
    var maximumCount = 100
    var retentionDays = 7
    var saveLocally = false
    var excludedApplications: Set<String> = []
    var captureText = true
    var captureImages = true
    var capturePolicy: ClipboardCapturePolicy { .init(text: captureText, images: captureImages) }
    private enum CodingKeys: String, CodingKey { case maximumCount, retentionDays, saveLocally, excludedApplications, captureText, captureImages }
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maximumCount = try values.decode(Int.self, forKey: .maximumCount)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
        saveLocally = try values.decode(Bool.self, forKey: .saveLocally)
        excludedApplications = try values.decode(Set<String>.self, forKey: .excludedApplications)
        captureText = try values.decodeIfPresent(Bool.self, forKey: .captureText) ?? true
        captureImages = try values.decodeIfPresent(Bool.self, forKey: .captureImages) ?? true
        normalize()
    }
    mutating func normalize() { maximumCount = min(1000, max(1, maximumCount)); retentionDays = min(30, max(1, retentionDays)); excludedApplications = Set(excludedApplications.filter { !$0.isEmpty && $0.utf8.count <= 255 }.sorted().prefix(128)) }
}

/// Classify pasteboard items before materializing representations; never strip a mixed copy's formats.
struct ClipboardCapturePolicy: Equatable, Sendable {
    var text = true
    var images = true
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg"]
    var hasEnabledType: Bool { text || images }
    func allows(_ types: Set<String>) -> Bool { types.isDisjoint(with: Self.imageTypes) ? text : images }
    func allows(_ items: [ClipboardContent]) -> Bool {
        hasEnabledType && !items.isEmpty && items.allSatisfy { allows(Set($0.representations.keys)) }
    }
}

struct V2ClipboardSnapshot: Sendable {
    let generation: Int
    let items: [ClipboardContent]
    let application: String
    var marker: String? = nil
    var sensitive = false
}

@MainActor protocol ClipboardSource: AnyObject {
    var generation: Int { get }
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot?
    func read(expectedGeneration: Int, excluding: Set<String>, policy: ClipboardCapturePolicy) -> V2ClipboardSnapshot?
}
extension ClipboardSource {
    /// Legacy/fake sources keep source compatibility; Native overrides to reject before data reads.
    func read(expectedGeneration: Int, excluding: Set<String>, policy: ClipboardCapturePolicy) -> V2ClipboardSnapshot? {
        guard policy.hasEnabledType, let snapshot = read(expectedGeneration: expectedGeneration, excluding: excluding), policy.allows(snapshot.items) else { return nil }
        return snapshot
    }
}
enum ClipboardWriteResult: Equatable { case copied(generation: Int), changed, failed }
@MainActor protocol ClipboardWriting: AnyObject {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult
}
