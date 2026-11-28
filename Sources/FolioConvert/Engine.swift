public import Foundation

/// One converter per file family. Implementations live next to this file
/// (`ImageConverter`, `PDFConverter`, …) and only know how to turn one input into one output.
/// Routing, naming, conflicts, atomic moves, size rules and scheduling are the engine's job.
public nonisolated protocol FamilyConverter: Sendable {
    static var family: Format.Family { get }
    /// Every format `source` can become, including itself when compressing is supported.
    static func targets(from source: Format) -> [Target]
    /// Write `job.output`. Throw ``ConvertError`` for anything the caller can act on.
    static func convert(_ job: Job) async throws -> Outcome
    /// Key facts for `folio inspect`: pages, dimensions, duration, codecs, sheets…
    static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue]
    /// The file's content as Markdown or plain text, for agents to read.
    static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String
    /// Which scheduler queue the job runs on.
    static func resource(for job: Job) -> Resource
}

public nonisolated extension FamilyConverter {
    static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] { [:] }
    static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String {
        throw ConvertError(.unsupportedInput, "Folio can't read text out of \(format.title) files.")
    }
    static func resource(for job: Job) -> Resource { .cpu }
}

public nonisolated enum ExtractKind: String, Codable, Sendable { case markdown, text }

public nonisolated struct ExtractOptions: Sendable {
    /// 1-based, inclusive page range for PDFs and paginated documents.
    public var pages: ClosedRange<Int>?
    /// Spreadsheet sheet name; `nil` means every sheet.
    public var sheet: String?
    public init(pages: ClosedRange<Int>? = nil, sheet: String? = nil) {
        self.pages = pages
        self.sheet = sheet
    }
}

/// Scheduler queues. CPU codecs scale with cores; the media engine and AppKit printing don't.
public nonisolated enum Resource: Sendable, CaseIterable {
    /// ImageIO JPEG/PNG/AVIF, documents, spreadsheets, audio: one job per core.
    case cpu
    /// Hardware image encoders (HEIC): more than a few in flight doesn't help.
    case hardwareImage
    /// Video re-encodes: one media engine on base Apple silicon.
    case videoEncode
    /// Remux and passthrough: I/O-bound.
    case io

    var width: Int {
        switch self {
        case .cpu: ProcessInfo.processInfo.activeProcessorCount
        case .hardwareImage: 3
        case .videoEncode: 1
        case .io: 8
        }
    }
}

/// What a file is and what it can become. `folio inspect` and MCP `folio_inspect`.
public nonisolated struct FileInfo: Codable, Sendable {
    public var path: String
    public var kind: Format.Family?
    public var format: Format?
    public var bytes: Int64
    public var meta: [String: JSONValue]
    public var targets: [Target]
    public var error: ConvertError?
}

/// The conversion engine. Stateless and safe to call from any thread.
public nonisolated enum Engine {
    public static let converters: [any FamilyConverter.Type] = [
        ImageConverter.self, PDFConverter.self, DocumentFamilyConverter.self, SheetConverter.self,
        AudioConverter.self, VideoConverter.self,
    ]

    static func converter(for format: Format) -> any FamilyConverter.Type {
        converters.first { $0.family == format.family }!
    }

    /// Every supported pair, for `folio formats`, docs and the Quick Action menus.
    public static func formats() -> [(from: Format, targets: [Target])] {
        Format.allCases.map { ($0, converter(for: $0).targets(from: $0)) }.filter { !$0.targets.isEmpty }
    }

    public static func targets(for url: URL) -> [Target] {
        guard let format = Format.detect(url) else { return [] }
        return converter(for: format).targets(from: format)
    }

    // MARK: Inspect and extract

    public static func inspect(_ url: URL) async -> FileInfo {
        let bytes = fileSize(url)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return FileInfo(path: url.path, bytes: 0, meta: [:], targets: [], error: ConvertError(.notFound, "No file at \(url.path)."))
        }
        guard let format = Format.detect(url) else {
            return FileInfo(
                path: url.path, bytes: bytes, meta: [:], targets: [],
                error: ConvertError(.unsupportedInput, "Folio doesn't know “.\(url.pathExtension)” files."))
        }
        let converter = converter(for: format)
        do {
            let meta = try await converter.inspect(url, format: format)
            return FileInfo(path: url.path, kind: format.family, format: format, bytes: bytes, meta: meta, targets: converter.targets(from: format))
        } catch {
            return FileInfo(
                path: url.path, kind: format.family, format: format, bytes: bytes, meta: [:], targets: converter.targets(from: format),
                error: wrap(error))
        }
    }

    public static func extract(_ url: URL, as kind: ExtractKind = .markdown, options: ExtractOptions = .init()) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ConvertError(.notFound, "No file at \(url.path).")
        }
        guard let format = Format.detect(url) else {
            throw ConvertError(.unsupportedInput, "Folio doesn't know “.\(url.pathExtension)” files.")
        }
        do { return try await converter(for: format).extract(url, format: format, as: kind, options: options) } catch { throw wrap(error) }
    }

    // MARK: Convert

    /// Runs a request: inputs in parallel within each resource's width, results in input order.
    ///
    /// `progress` gets the overall fraction (0…1) and the file it's working on.
    public static func run(_ request: ConvertRequest, progress: (@Sendable (Double, String) -> Void)? = nil) async -> ConvertReport {
        let start = ContinuousClock.now
        let names = NameReservations()
        let tracker = ProgressTracker(count: request.inputs.count, report: progress)
        let results = await withTaskGroup(of: (Int, ConvertResult).self) { group in
            for (index, input) in request.inputs.enumerated() {
                group.addTask {
                    let result = await convertOne(input, request: request, names: names) { fraction in
                        tracker.update(index, fraction, input.lastPathComponent)
                    }
                    tracker.update(index, 1, input.lastPathComponent)
                    return (index, result)
                }
            }
            var ordered = [ConvertResult?](repeating: nil, count: request.inputs.count)
            for await (index, result) in group { ordered[index] = result }
            return ordered.compactMap { $0 }
        }
        return ConvertReport(results: results, durationMs: start.milliseconds)
    }

    static func convertOne(
        _ input: URL, request: ConvertRequest, names: NameReservations, progress: @escaping @Sendable (Double) -> Void
    ) async -> ConvertResult {
        let start = ContinuousClock.now
        let bytesIn = fileSize(input)
        var result = ConvertResult(
            input: input.path, status: .failed, bytesIn: bytesIn, durationMs: 0, details: [:], dropped: [], warnings: [])
        func fail(_ error: any Error) -> ConvertResult {
            result.error = wrap(error)
            result.status = .failed
            result.durationMs = start.milliseconds
            return result
        }

        guard FileManager.default.fileExists(atPath: input.path(percentEncoded: false)) else {
            return fail(ConvertError(.notFound, "No file at \(input.path)."))
        }
        guard let source = Format.detect(input) else {
            return fail(ConvertError(.unsupportedInput, "Folio doesn't know “.\(input.pathExtension)” files."))
        }
        let target = request.target ?? source
        let converter = converter(for: source)
        let targets = converter.targets(from: source)
        guard let pair = targets.first(where: { $0.to == target }) else {
            let message =
                target == source
                ? "Folio can't compress \(source.title) files in place." : "Folio can't turn \(source.title) into \(target.title)."
            return fail(ConvertError(.unsupportedPair, message, hint: "Call folio_inspect to see the formats this file can become.", alternatives: targets))
        }
        if request.quality == .lossless && !pair.losslessAvailable {
            let lossless = targets.filter(\.losslessAvailable)
            return fail(
                ConvertError(
                    .losslessUnavailable, "\(target.title) can't hold \(source.title) without loss.",
                    hint: lossless.isEmpty ? "Use quality balanced." : "Lossless targets: \(lossless.map(\.to.rawValue).joined(separator: ", ")).",
                    alternatives: lossless))
        }

        let folder = request.outputDirectory ?? input.deletingLastPathComponent()
        let baseName = input.deletingPathExtension().lastPathComponent
        let planned = folder.appending(path: "\(baseName).\(target.fileExtension)")
        let existsAlready = FileManager.default.fileExists(atPath: planned.path(percentEncoded: false)) && planned.standardizedFileURL != input.standardizedFileURL
        if existsAlready, request.onConflict == .skip {
            result.status = .skipped
            result.output = planned.path
            result.warnings = ["\(planned.lastPathComponent) already exists"]
            result.durationMs = start.milliseconds
            return result
        }
        if existsAlready, request.onConflict == .fail {
            return fail(ConvertError(.outputExists, "\(planned.lastPathComponent) already exists.", hint: "Pass on_conflict rename or skip."))
        }

        if request.dryRun {
            result.status = .planned
            result.output = await names.preview(in: folder, name: baseName, ext: target.fileExtension)
            result.fidelity = request.quality == .lossless ? .lossless : pair.fidelity
            result.dropped = pair.drops
            result.durationMs = start.milliseconds
            return result
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appending(path: ".folio-\(UUID().uuidString).\(target.fileExtension)")
            defer { try? FileManager.default.removeItem(at: temp) }
            let job = Job(
                input: input, source: source, target: target, quality: request.quality, maxBytes: request.maxBytes,
                maxDimension: request.maxDimension, stripMetadata: request.stripMetadata,
                verify: request.verify ?? (request.quality == .lossless), output: temp, progress: progress)
            let outcome = try await Scheduler.shared.run(on: converter.resource(for: job)) {
                try Task.checkCancellation()
                return try await converter.convert(job)
            }
            if let verification = outcome.verification, !verification.passed {
                throw ConvertError(
                    .verificationFailed, "The output didn't match the input (\(verification.checks.joined(separator: ", "))).",
                    hint: "Nothing was written. Try quality balanced or another target.")
            }
            let bytesOut = outcome.isDirectory ? directorySize(temp) : fileSize(temp)
            if let maxBytes = request.maxBytes, !outcome.isDirectory, bytesOut > maxBytes {
                throw ConvertError(
                    .sizeUnreachable, "The smallest Folio could make was \(ByteCountFormatter.string(fromByteCount: bytesOut, countStyle: .file)).",
                    hint: "Raise max_bytes, lower max_dimension or pick a smaller format.")
            }
            result.fidelity = outcome.fidelity
            result.method = outcome.method
            result.details = outcome.details
            result.dropped = outcome.dropped
            result.warnings = outcome.warnings
            result.verification = outcome.verification

            // Never-bigger rule: a "compressed" copy that isn't smaller isn't worth keeping.
            if target == source, request.quality != .lossless, !outcome.isDirectory, Double(bytesOut) >= Double(bytesIn) * 0.98 {
                result.status = .skipped
                result.bytesOut = bytesIn
                result.ratio = 1
                result.warnings.append("Already compact: the compressed copy wasn't smaller, so the original is kept as is.")
                result.durationMs = start.milliseconds
                return result
            }

            let final = try await names.claim(in: folder, name: baseName, ext: outcome.isDirectory ? "" : target.fileExtension) { url in
                try FileManager.default.moveItem(at: temp, to: url)  // moveItem refuses to overwrite
            }
            result.output = final.path
            result.bytesOut = bytesOut
            result.ratio = bytesIn > 0 ? (Double(bytesOut) / Double(bytesIn) * 1000).rounded() / 1000 : nil
            result.status = .ok
            result.durationMs = start.milliseconds
            return result
        } catch {
            return fail(error)
        }
    }

    static func wrap(_ error: any Error) -> ConvertError {
        if let error = error as? ConvertError { return error }
        if error is CancellationError { return ConvertError(.cancelled, "Cancelled.") }
        return ConvertError(.internal, error.localizedDescription)
    }

    public static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? []
        return items.reduce(0) { $0 + fileSize($1) }
    }
}

/// Hands out output names so parallel jobs never race for the same "name 2.ext".
actor NameReservations {
    private var claimed: Set<String> = []

    func preview(in folder: URL, name: String, ext: String) -> String {
        candidate(in: folder, name: name, ext: ext).path
    }

    /// Picks a free name and runs `place` (an atomic, non-overwriting move) into it.
    func claim(in folder: URL, name: String, ext: String, place: (URL) throws -> Void) throws -> URL {
        for _ in 0..<1000 {
            let url = candidate(in: folder, name: name, ext: ext)
            claimed.insert(url.path)
            do {
                try place(url)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue  // someone outside Folio took it meanwhile
            }
        }
        throw ConvertError(.outputExists, "Couldn't find a free name for \(name).")
    }

    private func candidate(in folder: URL, name: String, ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var url = folder.appending(path: "\(name)\(suffix)")
        var n = 2
        while claimed.contains(url.path) || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(name) \(n)\(suffix)")
            n += 1
        }
        return url
    }
}

/// Per-resource concurrency limits, shared by every caller in the process.
actor Scheduler {
    static let shared = Scheduler()
    private var running: [Resource: Int] = [:]
    private var waiting: [Resource: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func run<T: Sendable>(on resource: Resource, _ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(resource)
        do {
            let value = try await body()
            await release(resource)
            return value
        } catch {
            await release(resource)
            throw error
        }
    }

    private func acquire(_ resource: Resource) async {
        if running[resource, default: 0] < resource.width {
            running[resource, default: 0] += 1
            return
        }
        await withCheckedContinuation { waiting[resource, default: []].append($0) }
    }

    private func release(_ resource: Resource) {
        if var queue = waiting[resource], !queue.isEmpty {
            queue.removeFirst().resume()  // hand the slot straight over
            waiting[resource] = queue
        } else {
            running[resource, default: 1] -= 1
        }
    }
}

/// Folds per-file fractions into one overall fraction.
nonisolated final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private let report: (@Sendable (Double, String) -> Void)?

    init(count: Int, report: (@Sendable (Double, String) -> Void)?) {
        fractions = Array(repeating: 0, count: max(count, 1))
        self.report = report
    }

    func update(_ index: Int, _ fraction: Double, _ name: String) {
        guard let report else { return }
        lock.lock()
        fractions[index] = min(max(fraction, fractions[index]), 1)
        let total = fractions.reduce(0, +) / Double(fractions.count)
        lock.unlock()
        report(total, name)
    }
}

extension ContinuousClock.Instant {
    nonisolated var milliseconds: Int {
        let d = ContinuousClock.now - self
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
