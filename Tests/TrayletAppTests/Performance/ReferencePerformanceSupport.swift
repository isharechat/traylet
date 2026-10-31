import AppKit
import Darwin
import CryptoKit
import Foundation
import Testing
@testable import TrayletApp

/// Synthetic, opt-in measurements. This is a process baseline, never an acceptance threshold.
@MainActor final class ReferencePerformanceReport {
    static let warmups = 3
    static let samples = 20
    private let destination: URL
    private var report: Report

    struct Memory: Codable {
        let residentBytes: UInt64?
        let processLifetimePeakResidentBytes: Int64?
        let interpretation = "Absolute process values; include runner, fixtures and previous cases. Not operation allocations or attributed deltas. Darwin ru_maxrss is bytes."
    }
    struct Metric: Codable {
        let name: String
        let scale: [String: Int]
        let timing: String
        let notes: String
        let warmupCount: Int
        let sampleCount: Int
        let rawMilliseconds: [Double]
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let memoryBefore: Memory
        let memoryAfter: Memory
    }
    struct Report: Codable {
        let schemaVersion = 1
        let startedAt = Date()
        var completedAt: Date?
        var completed = false
        let configuration: String
        let host: [String: String]
        let sourceHashesAtStart: [String: String]
        var sourceHashesAtEnd: [String: String] = [:]
        let sourceHashScope = "Repository Sources, all compiled TrayletAppTests, Package.swift and swift-local.sh; runtime disk snapshots, not embedded compiler provenance. Check build log and snapshots for concurrent edits."
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let processorCount = ProcessInfo.processInfo.processorCount
        let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount
        let percentileMethod = "Nearest rank: sorted[ceil(p * n) - 1]; 20 samples give an exploratory p95, not a tail-latency guarantee. Warmups excluded."
        let validation = "Completion means sampling finished. Use results only with the matching Swift Testing pass/exit code; correctness assertions are outside timed intervals."
        let scope = "Synthetic local fixtures; no general pasteboard, screen capture, network, AI, user data, keys, installation, foreground UI or permissions."
        let unmeasured = [
            "Real capture/hotkey-to-overlay and LaunchServices latency; synthetic rendering does not measure them.",
            "Scrolling capture: no current module; not measurable and not restored.",
            "SwiftUI list rendering, real pasteboard polling, disk persistence, energy and CPU utilization.",
            "MainActor blocking for async refresh: reported wall time includes executor scheduling, not a synchronous-blocking measurement."
        ]
        var metrics: [Metric] = []
    }

    init() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TRAYLET_REFERENCE_PERF_DIR"], "Opt-in runs require an explicit absolute output directory")
        #expect(path.hasPrefix("/"))
        guard path.hasPrefix("/") else { throw Failure.relativeDirectory }
        destination = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("reference-performance.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        var machine = utsname()
        uname(&machine)
        let machineCapacity = MemoryLayout.size(ofValue: machine.machine)
        let architecture = withUnsafePointer(to: &machine.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
        }
        report = Report(configuration: configuration, host: [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "hostName": ProcessInfo.processInfo.hostName,
            "runner": "Swift Testing; scripts/swift-local.sh test --no-parallel",
            "sdkPath": ProcessInfo.processInfo.environment["TRAYLET_SDK_PATH"] ?? "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk (script default)",
            "pid": String(ProcessInfo.processInfo.processIdentifier)
        ], sourceHashesAtStart: try Self.sourceHashes())
        try flush()
    }

    /// Fixture construction and result validation are outside the synchronous MainActor interval.
    func sync<Fixture, Output>(_ name: String, scale: [String: Int], notes: String,
                               prepare: () async throws -> Fixture,
                               operation: (Fixture) throws -> Output,
                               validate: (Fixture, Output) throws -> Void) async throws {
        var raw: [Double] = []
        let before = memory()
        for index in 0..<(Self.warmups + Self.samples) {
            let fixture = try await prepare()
            let (elapsed, output) = try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let output = try operation(fixture)
                return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, output)
            }
            try validate(fixture, output)
            if index >= Self.warmups { raw.append(elapsed) }
        }
        try append(name, scale: scale, timing: "synchronous MainActor interval; fixture setup and correctness assertions excluded", notes: notes, raw: raw, before: before)
    }

    /// Async operations are measured as wall time; no claim about continuous MainActor occupation.
    func asynchronous<Fixture, Output>(_ name: String, scale: [String: Int], notes: String,
                                       prepare: () async throws -> Fixture,
                                       operation: (Fixture) async throws -> Output,
                                       validate: (Fixture, Output) throws -> Void) async throws {
        var raw: [Double] = []
        let before = memory()
        for index in 0..<(Self.warmups + Self.samples) {
            let fixture = try await prepare()
            let start = DispatchTime.now().uptimeNanoseconds
            let output = try await operation(fixture)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            try validate(fixture, output)
            if index >= Self.warmups { raw.append(elapsed) }
        }
        try append(name, scale: scale, timing: "async wall time from MainActor; includes executor scheduling; setup and assertions excluded", notes: notes, raw: raw, before: before)
    }

    func finish() throws {
        report.sourceHashesAtEnd = try Self.sourceHashes()
        report.completed = true
        report.completedAt = Date()
        try flush()
        print("REFERENCE_PERF_JSON \(destination.path)")
    }

    private func append(_ name: String, scale: [String: Int], timing: String, notes: String, raw: [Double], before: Memory) throws {
        let sorted = raw.sorted()
        func percentile(_ value: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * value)) - 1)] }
        let metric = Metric(name: name, scale: scale, timing: timing, notes: notes, warmupCount: Self.warmups, sampleCount: raw.count,
                            rawMilliseconds: raw, p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95), memoryBefore: before, memoryAfter: memory())
        report.metrics.append(metric)
        try flush() // Partial runs remain explicitly incomplete and retain completed samples.
        print("REFERENCE_PERF \(name) \(scale) n=\(raw.count) p50=\(metric.p50Milliseconds)ms p95=\(metric.p95Milliseconds)ms")
    }
    private func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: destination, options: .atomic)
    }
    private func memory() -> Memory {
        var usage = rusage()
        let hasPeak = getrusage(RUSAGE_SELF, &usage) == 0
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Memory(residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
                      processLifetimePeakResidentBytes: hasPeak ? Int64(usage.ru_maxrss) : nil)
    }
    private static func sourceHashes() throws -> [String: String] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        var paths = ["Package.swift", "scripts/swift-local.sh"]
        for folder in ["Sources", "Tests/TrayletAppTests"] {
            let directory = root.appendingPathComponent(folder)
            if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                for case let file as URL in enumerator where file.pathExtension == "swift" {
                    paths.append(String(file.path.dropFirst(root.path.count + 1)))
                }
            }
        }
        return try Dictionary(uniqueKeysWithValues: paths.sorted().map { path in
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path)))
            return (path, digest.map { String(format: "%02x", $0) }.joined())
        })
    }
    private enum Failure: Error { case relativeDirectory }
}

@MainActor final class ReferenceClipboardSource: ClipboardSource {
    var generation = 0
    var snapshot: V2ClipboardSnapshot?
    var reads = 0
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? {
        reads += 1
        guard let snapshot, snapshot.generation == expectedGeneration, !excluding.contains(snapshot.application) else { return nil }
        return snapshot
    }
}
@MainActor final class ReferenceClipboardWriter: ClipboardWriting {
    private(set) var writes = 0
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { writes += 1; return .failed }
}

/// The archive seam only seeds the fixture. No encoding, files, persistence or actor hops are timed.
struct ReferenceMemoryArchive: V2ClipboardArchiving {
    let entries: [ClipboardEntry]
    func load() async throws -> [ClipboardEntry] { entries }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) async throws {}
    func clear(revision: UInt64) async throws {}
    func loadSettings() async throws -> ClipboardSettings? { nil }
    func saveSettings(_ settings: ClipboardSettings) async throws {}
    func loadFavorites() async throws -> [ClipboardEntry] { [] }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) async throws {}
    func clearFavorites(revision: UInt64) async throws {}
}
