import AVFoundation
import Speech

/// On-device transcription of an audio file, in timed segments. SpeechAnalyzer on macOS 26 and later,
/// SFSpeechRecognizer limited to on-device recognition before that. Nothing leaves the Mac.
enum Transcription {
    enum Failure: LocalizedError {
        case notAllowed, unavailable

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Speech recognition is not allowed (System Settings > Privacy & Security > Speech Recognition)."
            case .unavailable: "On-device speech recognition is not available for this language."
            }
        }
    }

    /// Asks for speech recognition the first time; macOS remembers the answer.
    static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard await authorize() else { throw Failure.notAllowed }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return try await analyze(audio, locale: locale)
        }
        return try await recognize(audio)
    }

    // MARK: macOS 26

    @available(macOS 26, *)
    private static func analyze(_ audio: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // The language model downloads once, the first time a language is used.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = transcriber.results.reduce(into: [TranscriptSegment]()) { segments, result in
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    // MARK: macOS 15

    private static func recognize(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        var collector: WordCollector?
        let words = try await withCheckedThrowingContinuation { continuation in
            collector = WordCollector(continuation)
            _ = recognizer.recognitionTask(with: request, delegate: collector!)
        }
        // The delegate is held here until the task has finished.
        withExtendedLifetime(collector) {}
        return TranscriptSegment.sentences(from: words)
    }

    /// Long files come back as several final results; the task says when the last one is in.
    private final class WordCollector: NSObject, SFSpeechRecognitionTaskDelegate {
        private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
        private var words: [TranscriptSegment] = []

        init(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
            self.continuation = continuation
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
            words += result.bestTranscription.segments.map {
                TranscriptSegment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
            }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            // A file with no speech ends unsuccessfully: that is an empty transcript, not an error.
            continuation?.resume(returning: words)
            continuation = nil
        }
    }
}
