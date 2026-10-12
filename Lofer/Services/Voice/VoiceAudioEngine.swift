// AVFoundation predates Swift concurrency annotations; its audio buffers are only touched on one thread here.
@preconcurrency import AVFoundation
import os

/// Voice diagnostics in the Xcode console (filter: "voice"). Never what the user said: only
/// what happened and how much (counts, lengths, levels).
let voiceLog = Logger(subsystem: "com.lofer.app", category: "voice")

/// The microphone and the speaker for real voice. One `AVAudioEngine` carries both while
/// Lofer is listening: iOS's voice processing then cancels Lofer's own voice from the
/// microphone (echo cancellation), which only works when playback and recording share an engine.
/// When Lofer isn't listening, speech plays through a separate playback-only engine, so the
/// microphone is fully off (no orange dot) while the user types.
///
/// Audio formats: the microphone is converted to 16 kHz 16-bit mono (what Scribe expects);
/// speech arrives as 16-bit mono at the rate the backend reports (24 kHz).
/// No Bluetooth permission is needed: playback can use AirPods, recording uses the built-in mic
/// unless a wired headset is plugged in.
@MainActor
final class VoiceAudioEngine {
    nonisolated static let captureSampleRate: Double = 16_000

    /// One engine plus the node that plays Lofer's voice.
    private final class Graph {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var playerFormat: AVAudioFormat?
        init() { engine.attach(player) }
    }
    private var captureGraph: Graph?                       // exists only while listening
    private var playbackOnly: Graph?                       // created the first time Lofer speaks without listening
    private var playbackGraph: Graph { if let g = playbackOnly { return g }; let g = Graph(); playbackOnly = g; return g }
    private var graph: Graph { captureGraph ?? playbackGraph }
    /// Recent restarts after audio configuration changes, so a reconfiguration loop can't run forever.
    private var recentRestarts: [Date] = []

    /// Each line Lofer speaks gets an id; buffers and callbacks from an older line are ignored.
    private var playbackId = 0
    private var buffersPending = 0
    private var streamEnded = false
    private var drained: CheckedContinuation<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var onChunk: (@Sendable (Data) -> Void)?

    // MARK: Session + permission

    func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try session.setActive(true)
    }

    // MARK: Microphone

    /// Starts recording. `onChunk` receives 16 kHz 16-bit mono PCM on an audio thread.
    func startCapture(onChunk: @escaping @Sendable (Data) -> Void) throws {
        stopCapture()
        stopPlayback()
        // Only one engine at a time: two engines fighting over the same audio device keep
        // reconfiguring it (and on the simulator the microphone then delivers nothing).
        playbackOnly?.engine.stop()
        try activateSession()
        let g = Graph()
        let input = g.engine.inputNode
        // Echo cancellation, on a real iPhone. The simulator's audio device doesn't support it
        // properly (it reconfigures endlessly); there the text echo guard does the work.
        #if !targetEnvironment(simulator)
        do { try input.setVoiceProcessingEnabled(true) } catch { voiceLog.error("Echo cancellation unavailable: \(error.localizedDescription, privacy: .public)") }
        #endif
        let micFormat = input.outputFormat(forBus: 0)
        voiceLog.info("Microphone format: \(micFormat.sampleRate, privacy: .public) Hz, \(micFormat.channelCount, privacy: .public) channel(s)")
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0,
              let tap = Self.makeTap(from: micFormat, onChunk: onChunk) else {
            voiceLog.error("No usable microphone input")
            throw VoiceProblem.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: tap)
        g.engine.connect(g.player, to: g.engine.mainMixerNode, format: nil)
        g.engine.prepare()
        do { try g.engine.start() } catch {
            input.removeTap(onBus: 0)
            voiceLog.error("Audio engine didn't start: \(error.localizedDescription, privacy: .public)")
            throw VoiceProblem.microphoneUnavailable
        }
        captureGraph = g
        self.onChunk = onChunk
        observeConfigurationChanges(of: g.engine)
        voiceLog.info("Microphone capture started")
    }

    func stopCapture() {
        guard let g = captureGraph else { return }
        if g.player.isPlaying { stopPlayback() }
        g.engine.inputNode.removeTap(onBus: 0)
        g.engine.stop()
        try? g.engine.inputNode.setVoiceProcessingEnabled(false)
        captureGraph = nil; onChunk = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    /// Converts whatever the microphone delivers into 16 kHz mono Int16 chunks. Built outside
    /// the main actor because the tap runs on a real-time audio thread.
    nonisolated private static func makeTap(from micFormat: AVAudioFormat, onChunk: @escaping @Sendable (Data) -> Void) -> AVAudioNodeTapBlock? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: captureSampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: micFormat, to: target) else { return nil }
        let ratio = captureSampleRate / micFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            onChunk(Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
        }
    }

    /// Plugging in headphones (or similar) can stop the engine. Start the SAME engine again; only
    /// rebuild if that fails, and at most 3 times in 10 s, so a change can't trigger an endless loop.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    private func configurationChanged() {
        guard let g = captureGraph, let onChunk else { return }
        voiceLog.info("Audio configuration changed")
        if g.engine.isRunning { return }
        if (try? g.engine.start()) != nil { voiceLog.info("Audio engine restarted"); return }
        recentRestarts = recentRestarts.filter { Date().timeIntervalSince($0) < 10 } + [Date()]
        guard recentRestarts.count <= 3 else {
            voiceLog.error("Audio keeps reconfiguring; stopping the microphone")
            stopCapture()
            return
        }
        try? startCapture(onChunk: onChunk)
    }

    // MARK: Speaker

    /// Prepares to play a new line of 16-bit mono PCM at `sampleRate`. Returns its id.
    func beginPlayback(sampleRate: Double) throws -> Int {
        stopPlayback()
        try activateSession()
        let g = graph
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw VoiceProblem.unavailable }
        if g.playerFormat != format {
            g.engine.disconnectNodeOutput(g.player)
            g.engine.connect(g.player, to: g.engine.mainMixerNode, format: format)
            g.playerFormat = format
        }
        if !g.engine.isRunning { g.engine.prepare(); try g.engine.start() }
        playbackId += 1; buffersPending = 0; streamEnded = false
        return playbackId
    }

    /// Queues a piece of the line. Playback starts with the first piece.
    func enqueue(_ pcm16: Data, playback id: Int) {
        let g = graph
        guard id == playbackId, let format = g.playerFormat,
              let buffer = Self.floatBuffer(from: pcm16, format: format) else { return }
        buffersPending += 1
        g.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.onPlayed { [weak self] in
            self?.bufferPlayed(id)
        })
        if !g.player.isPlaying { g.player.play() }
    }

    /// Waits until everything queued for this line has been heard (or playback was stopped).
    func finishPlayback(_ id: Int) async {
        guard id == playbackId else { return }
        streamEnded = true
        if buffersPending == 0 { return }
        await withCheckedContinuation { drained = $0 }
    }

    func stopPlayback() {
        playbackId += 1
        graph.player.stop()
        buffersPending = 0
        drained?.resume(); drained = nil
    }

    private func bufferPlayed(_ id: Int) {
        guard id == playbackId else { return }
        buffersPending = max(0, buffersPending - 1)
        if buffersPending == 0, streamEnded { drained?.resume(); drained = nil }
    }

    /// Completion handlers run on an audio thread; hop back to the main actor.
    nonisolated private static func onPlayed(_ work: @escaping @Sendable @MainActor () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { @Sendable _ in Task { @MainActor in work() } }
    }

    nonisolated static func floatBuffer(from pcm16: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm16.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return nil }
        pcm16.withUnsafeBytes { raw in
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
