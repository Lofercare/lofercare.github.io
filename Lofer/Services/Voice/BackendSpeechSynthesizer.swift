import Foundation

/// TEXT-TO-SPEECH through Lofer's backend (which calls ElevenLabs with the server-side key).
/// One HTTP request per complete line; the audio is played as it streams in, so Lofer starts
/// talking before the whole line has arrived. Stopping cancels the request, which also stops
/// generation on the server.
@MainActor
final class BackendSpeechSynthesizer: SpeechSynthesisService {
    private let backend: VoiceBackendClient
    private let audio: VoiceAudioEngine
    private var current: Task<Void, Error>?

    init(backend: VoiceBackendClient, audio: VoiceAudioEngine) { self.backend = backend; self.audio = audio }

    func speak(_ text: String) async throws {
        stop()
        let task = Task { try await play(text) }
        current = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func stop() {
        current?.cancel(); current = nil
        audio.stopPlayback()
    }

    private func play(_ text: String) async throws {
        let request = backend.speechRequest(text)
        let session = backend.session
        var playback: Int?
        // Downloading happens off the main actor; every ~100 ms of audio hops back to be queued.
        try await Self.download(request, session: session) { [weak self] sampleRate, chunk in
            guard let self, !Task.isCancelled else { return }
            if playback == nil { playback = try? audio.beginPlayback(sampleRate: sampleRate) }
            if let playback { audio.enqueue(chunk, playback: playback) }
        }
        try Task.checkCancellation()
        if let playback { await audio.finishPlayback(playback) }
        try Task.checkCancellation()
    }

    /// Streams the response body, handing over whole 16-bit samples in ~100 ms pieces.
    nonisolated private static func download(_ request: URLRequest, session: URLSession,
                                             onAudio: @escaping @MainActor (Double, Data) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        do { try VoiceBackendClient.check(response) }
        catch { voiceLog.error("Speech request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)"); throw error }
        let sampleRate = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Sample-Rate")).flatMap(Double.init) ?? 24_000
        let pieceBytes = Int(sampleRate / 10) * 2
        var piece = Data(); piece.reserveCapacity(pieceBytes)
        for try await byte in bytes {
            piece.append(byte)
            if piece.count >= pieceBytes {
                let out = piece; piece.removeAll(keepingCapacity: true)
                await onAudio(sampleRate, out)
            }
        }
        if piece.count >= 2 { await onAudio(sampleRate, piece.prefix(piece.count & ~1)) }
    }
}
