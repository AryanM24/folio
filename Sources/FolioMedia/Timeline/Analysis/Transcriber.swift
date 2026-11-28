import AVFoundation
import FolioKit
import Speech
import Synchronization

/// Speech to words with times, on this Mac. Nothing leaves it: macOS 26 and later use
/// `SpeechAnalyzer` (Apple's on-device model, downloaded once per language by the system),
/// macOS 15 uses `SFSpeechRecognizer` with on-device recognition required.
///
/// Words come back in the file's own time, which is the model's source time, so captions
/// and text-based cuts follow the clip however it's later trimmed or moved.
nonisolated enum Transcriber {
    enum Stage: Sendable, Equatable {
        /// Reading the sound out of the file.
        case preparing
        /// The system is installing the speech model for the language (first use only).
        case downloadingModel
        case transcribing
    }

    typealias Progress = @Sendable (Stage, Double) -> Void

    /// Whether this Mac can transcribe at all (any language).
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false
    }

    /// The words spoken in `url`, cached by file and language.
    static func transcribe(
        _ url: URL, source: SourceID, locale: Locale = .current, cache: AnalysisCache? = .shared,
        progress: @escaping Progress = { _, _ in }
    ) async throws -> Transcript {
        let run = { try await words(in: url, locale: locale, progress: progress) }
        let result: Result
        if let cache {
            let key = try AnalysisCache.Key("transcript", media: url, parameters: [locale.identifier])
            result = try await cache.value(key, compute: run)
        } else {
            result = try await run()
        }
        progress(.transcribing, 1)
        return Transcript(sourceID: source, locale: result.locale, words: result.words)
    }

    struct Result: Codable, Sendable {
        var locale: String
        var words: [Word]
    }

    private static func words(in url: URL, locale: Locale, progress: @escaping Progress) async throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FolioTranscribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Both recognisers read a plain audio file; a movie's sound is copied out first.
        let audio = folder.appending(path: "speech.caf")
        let duration = try await extractSpeechAudio(from: url, to: audio) { progress(.preparing, $0) }
        if #available(macOS 26, *) {
            return try await analyze(audio, duration: duration, locale: locale, progress: progress)
        }
        return try await recognize(audio, locale: locale, progress: progress)
    }

    /// 16 kHz mono: what both recognisers run at, and small enough for an hour of speech.
    private static func extractSpeechAudio(
        from url: URL, to destination: URL, progress: @escaping AnalysisProgress
    ) async throws
        -> CMTime
    {
        let rate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw FolioError("Couldn't prepare the sound for transcription.")
        }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
            let channel = buffer.floatChannelData?[0]
        else { throw FolioError("Couldn't prepare the sound for transcription.") }
        return try await AudioReader.read(url, sampleRate: rate, channels: 1, progress: progress) { samples in
            var offset = 0
            while offset < samples.count {
                let n = min(chunk, samples.count - offset)
                channel.update(from: samples.baseAddress! + offset, count: n)
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                offset += n
            }
        }
    }

    // MARK: SpeechAnalyzer (macOS 26+)

    @available(macOS 26, *)
    private static func analyze(_ audio: URL, duration: CMTime, locale: Locale, progress: @escaping Progress) async throws -> Result {
        guard SpeechTranscriber.isAvailable else { throw FolioError("Transcription isn't available on this Mac.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw FolioError("Transcription isn't available in \(language(locale)).")
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        try await installModel(for: transcriber, progress: progress)

        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let total = max(duration.seconds, 0.001)
        progress(.transcribing, 0)
        async let collected = collect(transcriber.results) { progress(.transcribing, min(0.99, $0 / total)) }
        try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        let words = try await collected
        try Task.checkCancellation()
        return Result(locale: supported.identifier(.bcp47), words: words)
    }

    @available(macOS 26, *)
    private static func installModel(for transcriber: SpeechTranscriber, progress: @escaping Progress) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        progress(.downloadingModel, 0)
        let watcher = Task {
            while !Task.isCancelled {
                progress(.downloadingModel, request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        progress(.downloadingModel, 1)
    }

    @available(macOS 26, *)
    private static func collect(
        _ results: some AsyncSequence<SpeechTranscriber.Result, any Error>, reached: (Double) -> Void
    ) async throws -> [Word] {
        var words: [Word] = []
        for try await result in results {
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let start = Time(range.start), let length = Time(range.duration) else { continue }
                words.append(Word(text: text, range: TimeRange(start: start, duration: length), confidence: run.transcriptionConfidence))
            }
            reached(result.range.end.seconds)
        }
        return words.sorted { $0.range.start < $1.range.start }
    }

    // MARK: SFSpeechRecognizer (macOS 15)

    private static func recognize(_ audio: URL, locale: Locale, progress: @escaping Progress) async throws -> Result {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw FolioError("On-device transcription isn't available in \(language(locale)).")
        }
        try await authorize()
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        progress(.transcribing, 0)

        let once = Mutex<CheckedContinuation<[Word], any Error>?>(nil)
        // SFSpeechRecognitionTask.cancel() is safe from any thread.
        let task = Mutex<UncheckedSendable<SFSpeechRecognitionTask>?>(nil)
        let words = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Word], any Error>) in
                once.withLock { $0 = continuation }
                let started = recognizer.recognitionTask(with: request) { result, error in
                    // shortcut: keeps the last final result only; files the recogniser splits into
                    // several final results would lose all but the last. Fine for clips under ~1 hour.
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.compactMap { segment -> Word? in
                            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            return Word(
                                text: text,
                                range: TimeRange(start: Time(seconds: segment.timestamp), duration: Time(seconds: segment.duration)),
                                confidence: Double(segment.confidence))
                        }
                        once.withLock { $0.take()?.resume(returning: words) }
                    } else if let error {
                        once.withLock { $0.take()?.resume(throwing: FolioError("Transcription failed: \(error.localizedDescription)")) }
                    }
                }
                task.withLock { $0 = UncheckedSendable(started) }
                if Task.isCancelled {  // cancelled before the task existed to be cancelled
                    started.cancel()
                    once.withLock { $0.take()?.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            task.withLock { $0?.value.cancel() }
            once.withLock { $0.take()?.resume(throwing: CancellationError()) }
        }
        return Result(locale: locale.identifier(.bcp47), words: words)
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw FolioError(
                "Folio isn't allowed to recognise speech. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
        }
    }

    private static func language(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
