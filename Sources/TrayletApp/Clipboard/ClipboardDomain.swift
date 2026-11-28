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
        var hasText = false
        if let textData = representations[Self.textType] {
            guard let decoded = String(data: textData, encoding: .utf8) else { return false }
            hasText = !decoded.isEmpty
        }
        let images = representations.filter { ["public.png", "public.tiff", "public.jpeg"].contains($0.key) }
        guard hasText || !images.isEmpty else { return false }
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
    private static let itemTag = Data("item".utf8)
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
    static func digest(_ items: [ClipboardContent]) -> String {
        var hash = SHA256()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(bufferPointer: $0) }
            hash.update(data: data)
        }
        func appendUTF8(_ string: String) {
            var utf8 = string
            utf8.withUTF8 { buffer in
                var count = UInt64(buffer.count).bigEndian
                withUnsafeBytes(of: &count) { hash.update(bufferPointer: $0) }
                hash.update(bufferPointer: UnsafeRawBufferPointer(buffer))
            }
        }
        for item in items {
            append(itemTag)
            for key in item.representations.keys.sorted() { appendUTF8(key); append(item.representations[key]!) }
        }
        let digest = hash.finalize()
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in digest {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
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

    nonisolated static func imagePixelSize(for data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

private extension Character {
    /// Scripts that conventionally break between glyphs (Han, kana, Hangul and CJK punctuation)
    /// can wrap even without whitespace, so a long Chinese/Japanese/Korean run is not mistaken
    /// for a single unbreakable token.
    var breaksLikeCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,   // Hangul Jamo
                 0x2E80...0x9FFF,   // CJK radicals, symbols, kana, Hangul compatibility, ideographs
                 0xAC00...0xD7AF,   // Hangul syllables
                 0xF900...0xFAFF,   // CJK compatibility ideographs
                 0xFE30...0xFE4F,   // CJK compatibility forms
                 0x20000...0x2FA1F: // CJK extensions B–F and compatibility supplement
                return true
            default:
                return scalar.properties.isIdeographic
            }
        }
    }
}

enum ClipboardKind {
    case text, link, image
    var symbol: String { switch self { case .text: "text.alignleft"; case .link: "link"; case .image: "photo" } }
}

enum ClipboardKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, text, image, link
    var id: Self { self }
    func matches(_ kind: ClipboardKind) -> Bool {
        switch self {
        case .all: true
        case .text: kind == .text
        case .image: kind == .image
        case .link: kind == .link
        }
    }
}

/// What the list shows for an entry, computed once instead of decoding the body on every render.
struct ClipboardDisplay {
    let kind: ClipboardKind
    /// Validated `http` or `https` URL when `kind == .link`, otherwise `nil`.
    let linkURL: URL?
    /// Full plain text for search and preview; empty for images.
    let text: String
    /// One line of at most 200 characters for the row.
    let line: String?
    /// True when the preview renders this as one scrollable line (a URL or an unbreakable ASCII
    /// token) instead of wrapping by column width. Cached here so the view never rescans the body.
    let singleLine: Bool
    init(_ entry: ClipboardEntry) {
        let text = entry.plainText ?? ""
        self.text = text
        line = text.isEmpty ? nil : String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        if entry.imageData != nil { kind = .image; linkURL = nil; singleLine = false; return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normal text usually has a space near the start. Reject it before walking every grapheme
        // just to measure a long body that cannot be a standalone URL.
        var validatedLink: URL?
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), trimmed.count < 2048,
           let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            validatedLink = url
        }
        linkURL = validatedLink
        let looksLikeLink = validatedLink != nil
        kind = looksLikeLink ? .link : .text
        let hasWhitespace = text.contains(where: \.isWhitespace)
        let hasCJKBreak = text.contains(where: \.breaksLikeCJK)
        singleLine = looksLikeLink || (!hasWhitespace && !hasCJKBreak && text.count > 80)
    }
}

struct ClipboardSettings: Codable, Equatable, Sendable {
    var maximumCount = 100
    var retentionDays = 7
    var excludedApplications: Set<String> = []
    var captureText = true
    var captureImages = true
    var capturePolicy: ClipboardCapturePolicy { .init(text: captureText, images: captureImages) }
    private enum CodingKeys: String, CodingKey { case maximumCount, retentionDays, excludedApplications, captureText, captureImages }
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maximumCount = try values.decode(Int.self, forKey: .maximumCount)
        retentionDays = try values.decode(Int.self, forKey: .retentionDays)
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

struct ClipboardSnapshot: Sendable {
    let generation: Int
    let items: [ClipboardContent]
    let application: String
    var marker: String? = nil
    var sensitive = false
    var validated = false
}

@MainActor protocol ClipboardSource: AnyObject {
    var generation: Int { get }
    func read(expectedGeneration: Int, excluding: Set<String>) -> ClipboardSnapshot?
    func read(expectedGeneration: Int, excluding: Set<String>, policy: ClipboardCapturePolicy) -> ClipboardSnapshot?
}
extension ClipboardSource {
    /// Legacy/fake sources keep source compatibility; Native overrides to reject before data reads.
    func read(expectedGeneration: Int, excluding: Set<String>, policy: ClipboardCapturePolicy) -> ClipboardSnapshot? {
        guard policy.hasEnabledType, let snapshot = read(expectedGeneration: expectedGeneration, excluding: excluding), policy.allows(snapshot.items) else { return nil }
        return snapshot
    }
}
enum ClipboardWriteResult: Equatable { case copied(generation: Int), changed, failed }
@MainActor protocol ClipboardWriting: AnyObject {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult
}
