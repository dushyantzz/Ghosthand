import Foundation
import GhostHandCore

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

// MARK: - MacSpeechService
//
// macOS port of GhostHand.Platform.Speech.WindowsSpeechService (with the silence-based
// auto-stop from WhisperSpeechService). Dictation is performed entirely on-device with
// `SFSpeechRecognizer` + `AVAudioEngine`:
//
//   * Authorization for Speech Recognition and the microphone is requested up-front.
//   * A tap on the input node feeds an `SFSpeechAudioBufferRecognitionRequest`.
//   * Partial `bestTranscription.formattedString` values are published via `onRecognizing`.
//   * Recording finishes on silence, on the 30s safety cap, or when the caller's task is
//     cancelled (which stops the tap and throws `CancellationError`).
//
// The whole implementation is guarded by `canImport`, so the package still builds if the
// Speech/AVFoundation modules are unavailable; `transcribe()` then throws `.unavailable`.

/// Errors thrown by ``MacSpeechService``.
public enum MacSpeechError: Error, LocalizedError, Equatable {
    /// Speech/AVFoundation frameworks are not available on this platform.
    case unavailable
    /// The user has not granted Speech Recognition permission.
    case speechPermissionDenied
    /// The user has not granted microphone permission.
    case microphonePermissionDenied
    /// No audio input device (microphone) is connected.
    case noInputDevice
    /// `SFSpeechRecognizer` could not be created or is currently unavailable.
    case recognizerUnavailable
    /// `AVAudioEngine` failed to start.
    case audioEngineFailed(String)
    /// Recognition failed at runtime.
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition is unavailable on this system."
        case .speechPermissionDenied:
            return "Speech Recognition permission was denied. Enable it in System Settings > "
                + "Privacy & Security > Speech Recognition, then try again."
        case .microphonePermissionDenied:
            return "Microphone permission was denied. Enable it in System Settings > "
                + "Privacy & Security > Microphone, then try again."
        case .noInputDevice:
            return "No active microphone was detected. Connect a microphone or headset and try again."
        case .recognizerUnavailable:
            return "The speech recognizer is unavailable for the current language. "
                + "Download dictation languages in System Settings > Keyboard > Dictation, then try again."
        case let .audioEngineFailed(reason):
            return "Could not start the microphone audio engine: \(reason)"
        case let .recognitionFailed(reason):
            return "Speech recognition failed: \(reason)"
        }
    }
}

/// On-device dictation via `SFSpeechRecognizer` and `AVAudioEngine`.
public final class MacSpeechService: SpeechInput, @unchecked Sendable {

    /// Fired with partial/hypothesis text while recording is in progress.
    public var onRecognizing: ((String) -> Void)?

    public init() {}

    // MARK: - SpeechInput

    /// Records from the microphone and returns the final transcription.
    ///
    /// Resolves with the best available transcript when recording ends on silence or on
    /// the 30-second safety cap. Throws `CancellationError` if the calling task is
    /// cancelled, and a ``MacSpeechError`` when permissions/audio are unavailable.
    public func transcribe() async throws -> String {
        #if canImport(Speech) && canImport(AVFoundation)
        try Task.checkCancellation()

        try await Self.ensureAuthorized()

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw MacSpeechError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw MacSpeechError.recognizerUnavailable
        }
        if !recognizer.supportsOnDeviceRecognition {
            GhostLog.shared.warning(
                "MacSpeechService: on-device recognition is unavailable for "
                    + "\(recognizer.locale.identifier); falling back to network recognition."
            )
        }

        let session = MacSpeechSession(onRecognizing: onRecognizing)
        do {
            try session.start(recognizer: recognizer)
        } catch {
            session.teardown()
            throw error
        }

        while !session.isFinished {
            if Task.isCancelled {
                session.cancel()
                throw CancellationError()
            }
            if session.shouldAutoStop() {
                session.requestStop()
            }
            if session.shouldFinishWaiting {
                break
            }
            // Swallow sleep cancellation; the explicit `Task.isCancelled` check above
            // guarantees the session is torn down before we leave.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        session.teardown()

        if Task.isCancelled {
            throw CancellationError()
        }
        if let failure = session.failure, session.bestText.isEmpty {
            throw MacSpeechError.recognitionFailed(failure.localizedDescription)
        }

        let transcript = session.bestText
        GhostLog.shared.info(
            "MacSpeechService: transcription finished with \(transcript.count) character(s)."
        )
        return transcript
        #else
        throw MacSpeechError.unavailable
        #endif
    }

    // MARK: - Authorization

    #if canImport(Speech) && canImport(AVFoundation)
    private static func ensureAuthorized() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw MacSpeechError.speechPermissionDenied
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
            }
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MacSpeechError.microphonePermissionDenied
        }

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MacSpeechError.noInputDevice
        }
    }
    #endif
}

#if canImport(Speech) && canImport(AVFoundation)

// MARK: - MacSpeechSession
//
// Owns the audio engine, the recognition request/task and the shared transcript state.
// Callbacks arrive on arbitrary queues, so every mutable field is guarded by `lock`.

private final class MacSpeechSession: @unchecked Sendable {

    /// Stop after this much trailing silence (mirrors WhisperSpeechService's 1800ms).
    private static let silenceThreshold: TimeInterval = 1.8
    /// Never auto-stop before this much audio has been captured.
    private static let minimumRecording: TimeInterval = 0.5
    /// Hard safety cap on a single dictation session.
    private static let maximumRecording: TimeInterval = 30.0
    /// Grace period after stopping for the recognizer to deliver a final hypothesis.
    private static let graceAfterStop: TimeInterval = 1.2
    /// RMS below this is treated as silence.
    private static let silenceRMS: Float = 0.008

    private let onRecognizing: ((String) -> Void)?
    private let lock = NSLock()

    private var partialText = ""
    private var finalText: String?
    private var finished = false
    private var failureError: Error?
    private var stopRequestedAt: Date?
    private var sawSpeech = false
    private var lastVoiceAt = Date()
    private let startedAt = Date()

    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var audioStopped = false

    init(onRecognizing: ((String) -> Void)?) {
        self.onRecognizing = onRecognizing
    }

    // MARK: State

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    var failure: Error? {
        lock.lock(); defer { lock.unlock() }
        return failureError
    }

    /// Best transcript available: the final hypothesis when present, otherwise partials.
    var bestText: String {
        lock.lock(); defer { lock.unlock() }
        if let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return partialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once silence/stop has been detected and the recognizer has had its grace period.
    var shouldFinishWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return true }
        guard let stopRequestedAt else { return false }
        return Date().timeIntervalSince(stopRequestedAt) >= Self.graceAfterStop
    }

    func shouldAutoStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, stopRequestedAt == nil else { return false }
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= Self.maximumRecording { return true }
        if sawSpeech,
           elapsed >= Self.minimumRecording,
           now.timeIntervalSince(lastVoiceAt) >= Self.silenceThreshold {
            return true
        }
        return false
    }

    // MARK: Lifecycle

    func start(recognizer: SFSpeechRecognizer) throws {
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MacSpeechError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request.append(buffer)
            self.observe(buffer: buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopAudio()
            throw MacSpeechError.audioEngineFailed(error.localizedDescription)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    /// Ends the audio stream but lets the recognizer finish its current hypothesis.
    func requestStop() {
        lock.lock()
        if stopRequestedAt == nil { stopRequestedAt = Date() }
        lock.unlock()
        request.endAudio()
        stopAudio()
    }

    /// Immediate abort (caller cancellation).
    func cancel() {
        lock.lock()
        if stopRequestedAt == nil { stopRequestedAt = Date() }
        lock.unlock()
        request.endAudio()
        recognitionTask?.cancel()
        stopAudio()
    }

    /// Final cleanup; idempotent.
    func teardown() {
        request.endAudio()
        recognitionTask?.cancel()
        stopAudio()
    }

    // MARK: Audio

    private func stopAudio() {
        lock.lock()
        if audioStopped {
            lock.unlock()
            return
        }
        audioStopped = true
        let installed = tapInstalled
        tapInstalled = false
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }
        if installed {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func observe(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()

        lock.lock()
        if rms >= Self.silenceRMS {
            sawSpeech = true
            lastVoiceAt = Date()
        }
        lock.unlock()
    }

    // MARK: Recognition callbacks

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            lock.lock()
            partialText = text
            if isFinal {
                finalText = text
                finished = true
            }
            lock.unlock()

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onRecognizing?(trimmed)
            }
        }

        if let error {
            lock.lock()
            let hadStop = stopRequestedAt != nil
            let hadText = !(finalText ?? partialText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            // Cancellation errors raised by our own stop are expected; only surface
            // genuine failures that produced no transcript at all.
            if !hadStop && !hadText {
                failureError = error
            }
            finished = true
            lock.unlock()
        }
    }
}

#endif
