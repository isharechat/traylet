import AppKit
import Combine
import ImageIO
import TrayletCore

/// A single chosen history image. Original history representations are never rewritten.
struct ClipboardPreparedImage: Sendable {
    let image: RasterImage
    let pixels: CGImage
}

enum ClipboardImageDecoder {
    private static let worker = ClipboardImageDecodeWorker()
    static func prepare(_ data: Data) async throws -> ClipboardPreparedImage {
        try await worker.prepare(data)
    }
}

/// A serial executor bounds decompression even when the user cancels and immediately opens
/// another large image. ImageIO's synchronous operation cannot be interrupted mid-call.
private actor ClipboardImageDecodeWorker {
    func prepare(_ data: Data) throws -> ClipboardPreparedImage {
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= ClipboardPolicy.itemBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "public.tiff"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= ClipboardPolicy.imagePixels / height else {
                throw FeatureIssue.invalidInput("图片无效或超过安全尺寸。")
            }
            // Transform EXIF orientation while decoding exactly the selected image. The pixel
            // budget is checked before decompression; cancellation fences the synchronous codec.
            guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw FeatureIssue.invalidInput("图片暂时无法打开。") }
            try Task.checkCancellation()
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let png: Data
            if type == "public.png" && orientation == 1 { png = data }
            else {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                    throw FeatureIssue.invalidInput("图片暂时无法打开。")
                }
                CGImageDestinationAddImage(destination, pixels, nil)
                guard CGImageDestinationFinalize(destination), output.length <= 80 * 1_024 * 1_024 else {
                    throw FeatureIssue.invalidInput("图片无效或超过安全尺寸。")
                }
                png = output as Data
            }
            try Task.checkCancellation()
            return ClipboardPreparedImage(image: try RasterImage(pngData: png), pixels: pixels)
    }
}

@MainActor final class ClipboardImageEditing: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?
    private let prepare: @Sendable (Data) async throws -> ClipboardPreparedImage
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var sourceID: UUID?
    private var sourceDigest: String?
    init(prepare: @escaping @Sendable (Data) async throws -> ClipboardPreparedImage = ClipboardImageDecoder.prepare) { self.prepare = prepare }
    static func imageIndices(in entry: ClipboardEntry) -> [Int] { entry.items.indices.filter { entry.items[$0].imageData != nil } }
    @discardableResult func begin(entry: ClipboardEntry, itemIndex: Int, isCurrent: @escaping () -> Bool, open: @escaping (ClipboardPreparedImage) -> Bool) -> Task<Void, Never>? {
        guard !isPreparing else { return nil }
        guard entry.items.indices.contains(itemIndex), let data = entry.items[itemIndex].imageData else {
            message = "此条目没有可编辑的图片。"; return nil
        }
        revision = UUID(); let token = revision
        sourceID = entry.id; sourceDigest = entry.digest
        isPreparing = true; message = nil
        let prepare = prepare
        let work = Task { [weak self] in
            do {
                let result = try await prepare(data)
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.isPreparing = false; self.task = nil
                self.sourceID = nil; self.sourceDigest = nil
                guard isCurrent() else { return }
                if !open(result) { self.message = "请先完成或关闭当前编辑。" }
            } catch {
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.isPreparing = false; self.task = nil
                self.sourceID = nil; self.sourceDigest = nil
                self.message = "图片暂时无法打开。"
            }
        }
        task = work; return work
    }
    func reportUnavailable() { message = "请先完成或关闭当前编辑。" }
    func cancel() { task?.cancel(); task = nil; revision = UUID(); sourceID = nil; sourceDigest = nil; isPreparing = false; message = nil }
    func validate(entries: [ClipboardEntry]) {
        if let sourceID, !entries.contains(where: { $0.id == sourceID && $0.digest == sourceDigest }) { cancel() }
    }
}
