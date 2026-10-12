import Foundation

/// SPEECH-TO-TEXT with ElevenLabs Scribe v2 Realtime.
///
///   1. microphone permission
///   2. a single-use token from Lofer's backend (the permanent key never reaches the app)
///   3. a WebSocket to Scribe with that token; the microphone streams in 100 ms pieces
///   4. Scribe answers with partial transcripts while the user talks, and a committed
///      (final) transcript when they pause (voice activity detection)
///
/// Only text comes out of here. What it means is the care flow's job.
@MainActor
final class ScribeRealtimeRecognizer: SpeechRecognitionService {
    var onEvent: ((SpeechRecognitionEvent) -> Void)?
    private let backend: VoiceBackendClient
    private let audio: VoiceAudioEngine
    private let sender = AudioChunkSender()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// Bumped by every start and stop, so messages from an older connection are ignored.
    private var connection = 0

    /// How long a pause ends an utterance. Shorter feels snappier but cuts slow speakers off.
    static let silenceToCommit = 0.8

    init(backend: VoiceBackendClient, audio: VoiceAudioEngine) { self.backend = backend; self.audio = audio }

    static func url(token: String) -> URL {
        var c = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        c.queryItems = [
            .init(name: "model_id", value: "scribe_v2_realtime"),
            .init(name: "token", value: token),
            .init(name: "audio_format", value: "pcm_16000"),
            .init(name: "commit_strategy", value: "vad"),
            .init(name: "vad_silence_threshold_secs", value: String(silenceToCommit)),
            .init(name: "language_code", value: "en"),
        ]
        return c.url!
    }

    func start() async throws {
        stop()
        let mine = connection
        guard await audio.requestMicrophonePermission() else { voiceLog.error("Microphone permission denied"); throw VoiceProblem.microphoneDenied }
        let token: String
        do { token = try await backend.transcriptionToken() }
        catch { voiceLog.error("Speech-to-text token failed: \(String(describing: error), privacy: .public)"); throw error }
        guard mine == connection, !Task.isCancelled else { throw CancellationError() }
        voiceLog.info("Got a speech-to-text token; connecting to Scribe")

        let ws = URLSession.shared.webSocketTask(with: Self.url(token: token))
        socket = ws
        ws.resume()
        sender.attach(ws)
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do { message = try await ws.receive() }
                catch {
                    voiceLog.error("Scribe connection closed: \(error.localizedDescription, privacy: .public)")
                    self?.connectionDropped(mine); return
                }
                let text: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                guard let self, mine == connection, let text, let event = Self.event(from: text) else { continue }
                if case .failed = event { stop() }
                onEvent?(event)
            }
        }
        do { try audio.startCapture { [sender] chunk in sender.append(chunk) } }
        catch { stop(); throw error }
    }

    func stop() {
        connection += 1
        audio.stopCapture()
        sender.detach()
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    }

    func commitNow() { sender.commit() }

    private func connectionDropped(_ id: Int) {
        guard id == connection else { return }
        stop()
        onEvent?(.failed(.connectionLost))
    }

    /// Turns one Scribe message into an event (nil = nothing the app needs to know).
    nonisolated static func event(from json: String) -> SpeechRecognitionEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["message_type"] as? String else { return nil }
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch type {
        case "session_started", "partial_transcript", "committed_transcript":
            voiceLog.debug("Scribe: \(type, privacy: .public) (\(text.count, privacy: .public) characters)")
        default:
            voiceLog.info("Scribe: \(type, privacy: .public)")
        }
        switch type {
        case "session_started": return .started
        case "partial_transcript": return text.isEmpty ? nil : .partial(text)
        case "committed_transcript": return text.isEmpty ? nil : .final(text)
        // Can't be fixed by reconnecting: the account or the key.
        case "auth_error", "quota_exceeded", "unaccepted_terms": return .failed(.unavailable)
        // Temporary: a reconnect with a fresh token may help.
        case "error", "transcriber_error", "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded":
            return .failed(.connectionLost)
        // Harmless: silence, a commit too soon after another, warnings.
        default: return nil
        }
    }
}

/// Collects microphone audio into 100 ms pieces and sends each as one Scribe message.
/// Called from the audio thread, so it guards its state with a lock.
final class AudioChunkSender: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var pending = Data()
    private static let chunkBytes = Int(VoiceAudioEngine.captureSampleRate / 10) * 2   // 100 ms of 16-bit mono

    private var bytesSent = 0
    private var loudest: Int16 = 0          // the loudest sample since the last level report

    func attach(_ socket: URLSessionWebSocketTask) { lock.withLock { self.socket = socket; pending.removeAll(); bytesSent = 0; loudest = 0 } }
    func detach() { lock.withLock { socket = nil; pending.removeAll() } }

    func append(_ chunk: Data) {
        let ready: (URLSessionWebSocketTask, Data)? = lock.withLock {
            guard let socket else { return nil }
            pending.append(chunk)
            guard pending.count >= Self.chunkBytes else { return nil }
            defer { pending.removeAll(keepingCapacity: true) }
            reportLevel(of: pending)
            return (socket, pending)
        }
        if let (socket, audio) = ready { Self.send(audio, commit: false, on: socket) }
    }

    /// Sends what's buffered (or a moment of silence) and asks Scribe to finish the utterance now.
    func commit() {
        let ready: (URLSessionWebSocketTask, Data)? = lock.withLock {
            guard let socket else { return nil }
            defer { pending.removeAll(keepingCapacity: true) }
            return (socket, pending.isEmpty ? Data(count: Self.chunkBytes / 5) : pending)
        }
        if let (socket, audio) = ready { Self.send(audio, commit: true, on: socket) }
    }

    /// Every 3 s of audio, logs how loud the microphone was. Near −90 dB means it's hearing
    /// nothing at all (wrong input device, or no microphone access for the simulator).
    private func reportLevel(of audio: Data) {
        audio.withUnsafeBytes { raw in
            for i in stride(from: 0, to: audio.count - 1, by: 2) {
                let v = raw.loadUnaligned(fromByteOffset: i, as: Int16.self)
                loudest = max(loudest, v == .min ? .max : abs(v))
            }
        }
        let every = Int(VoiceAudioEngine.captureSampleRate) * 2 * 3
        if bytesSent == 0 { voiceLog.info("Microphone audio is flowing to Scribe") }
        if (bytesSent + audio.count) / every > bytesSent / every {
            let dB = 20 * log10(max(Double(loudest), 1) / 32768)
            voiceLog.info("Microphone level (last 3 s): \(Int(dB), privacy: .public) dB")
            loudest = 0
        }
        bytesSent += audio.count
    }

    static func message(_ audio: Data, commit: Bool) -> String {
        "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\(audio.base64EncodedString())\",\"commit\":\(commit),\"sample_rate\":\(Int(VoiceAudioEngine.captureSampleRate))}"
    }

    private static func send(_ audio: Data, commit: Bool, on socket: URLSessionWebSocketTask) {
        socket.send(.string(message(audio, commit: commit))) { _ in }   // a failed send shows up as a dropped connection
    }
}
