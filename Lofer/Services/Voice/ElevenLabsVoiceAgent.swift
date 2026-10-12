import Foundation
import Observation
import AVFoundation

/// REAL VOICE. ElevenLabs is used only as ears and a mouth; Lofer runs the conversation.
///
///   mic → SpeechRecognitionService (Scribe v2 Realtime) → final transcript → onTranscript
///       → AppModel → CareFlowModel (Care Intelligence → InvestigationEngine → SafetyValidator)
///       → say(line) → speak(line) → SpeechSynthesisService (ElevenLabs text-to-speech) → speaker
///
/// Rules this agent keeps:
///   • HANDS-FREE: tapping the mic starts listening, and it keeps listening after Lofer
///     answers, until the mic is tapped again (or nothing is said for a while).
///   • Only FINAL transcripts reach the app, each exactly once and in order. Something said
///     while the last utterance is still being handled waits its turn; it isn't dropped.
///   • It speaks exactly the text it's given (the line on screen). It never writes words itself.
///   • "Stop", "pause" or discomfort heard while Lofer is talking cuts the audio straight away
///     (and is passed on at once). The audio is all this agent stops: the care flow decides
///     what happens next, through its normal safety logic.
///   • Lofer's own voice coming back through the microphone is ignored (see VoiceInterrupts).
@Observable @MainActor
final class ElevenLabsVoiceAgent: VoiceAgent {
    private(set) var state: VoiceState = .idle
    private(set) var problem: VoiceProblem?
    var usesMicrophone: Bool { true }
    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?

    @ObservationIgnored private let recognizer: SpeechRecognitionService
    @ObservationIgnored private let synthesizer: SpeechSynthesisService
    /// When true, the user can talk over Lofer to cut it off (urgent words always can).
    @ObservationIgnored let bargeIn: Bool
    /// Stop listening after this long without hearing anything (privacy, and the meter is running).
    @ObservationIgnored let idleTimeout: Duration
    /// If the app never says it handled a transcript (e.g. the user left), stop waiting after this.
    @ObservationIgnored let handlingTimeout: Duration

    // Listening
    @ObservationIgnored private(set) var handsFree = false              // the user turned listening on
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    // Turn-taking
    @ObservationIgnored private var handling = false                    // a final transcript is with the app
    @ObservationIgnored private var queued: [String] = []               // finals heard meanwhile, in order
    @ObservationIgnored private var handlingTask: Task<Void, Never>?
    @ObservationIgnored private var lastFinal: (text: String, at: Date)?
    // Speaking
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    @ObservationIgnored private var currentLine: String?
    @ObservationIgnored private var lastLine: (text: String, endedAt: Date)?
    @ObservationIgnored private var cutOff = false                      // the user talked over the current line
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init(recognizer: SpeechRecognitionService, synthesizer: SpeechSynthesisService, bargeIn: Bool = true,
         idleTimeout: Duration = .seconds(120), handlingTimeout: Duration = .seconds(30),
         notifications: NotificationCenter = .default) {
        self.recognizer = recognizer; self.synthesizer = synthesizer; self.bargeIn = bargeIn
        self.idleTimeout = idleTimeout; self.handlingTimeout = handlingTimeout
        recognizer.onEvent = { [weak self] event in self?.handle(event) }
        // A phone call, Siri or an alarm takes the audio away: stop, and pick up again afterwards.
        interruptionObserver = notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { self?.audioInterrupted(began: began) }
        }
    }

    // MARK: - VoiceAgent

    func startListening() {
        if state == .speaking { interrupt() }
        problem = nil
        handsFree = true
        if state != .thinking { state = .listening }
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            do { try await recognizer.start() }
            catch {
                startTask = nil
                guard handsFree, !(error is CancellationError) else { return }
                fail(error as? VoiceProblem ?? .unavailable)
                return
            }
            startTask = nil
            restartIdleTimer()
        }
    }

    func stopListening() {
        handsFree = false
        startTask?.cancel(); startTask = nil
        idleTask?.cancel()
        recognizer.stop()
        queued.removeAll()
        if state == .listening || state == .error || state == .interrupted { state = .idle }
    }

    /// Typed text, or a tapped suggestion. It's newer than anything still playing, so Lofer
    /// stops talking, and it goes straight to the app (no speech service needed).
    func submitText(_ text: String, replay: TextReplay) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        stopSpeaking()
        queued.removeAll()
        deliver(t)
    }

    func speak(_ text: String) {
        stopSpeaking()
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        currentLine = line; cutOff = false
        state = .speaking
        speakTask = Task { [weak self] in
            guard let self else { return }
            do { try await synthesizer.speak(line) }
            catch { if Task.isCancelled { return } }      // a failed line is still on screen; carry on
            guard !Task.isCancelled else { return }
            finishedSpeaking()
        }
    }

    /// The user tapped the orb while Lofer was talking.
    func interrupt() {
        guard state == .speaking else { return }
        stopSpeaking()
        state = .interrupted
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, state == .interrupted else { return }
            state = restingState
        }
    }

    func transcriptHandled() {
        handlingTask?.cancel()
        handling = false
        if state == .thinking { state = restingState }
        if !queued.isEmpty { deliver(queued.removeFirst()) }
    }

    // MARK: - Recognition events

    private func handle(_ event: SpeechRecognitionEvent) {
        guard handsFree else { return }
        switch event {
        case .started:
            reconnectAttempts = 0
            if state == .idle || state == .error { state = .listening }
        case .partial(let text):
            restartIdleTimer()
            if state == .speaking {
                guard !VoiceInterrupts.isEcho(text, of: currentLine) else { return }
                if VoiceInterrupts.isUrgent(text) {
                    // "Stop" / "that hurts": cut the audio now and finish the utterance early.
                    cutIn(); recognizer.commitNow()
                } else if bargeIn && VoiceInterrupts.isBargeIn(text) {
                    cutIn()
                } else { return }
            }
            onTranscript?(text, false)
        case .final(let text):
            restartIdleTimer()
            heardFinal(text)
        case .failed(let problem):
            // One quick reconnect (a fresh single-use token) for a dropped connection; then give up.
            if problem == .connectionLost && reconnectAttempts == 0 {
                reconnectAttempts += 1
                recognizer.stop()
                startListening()
            } else {
                fail(problem)
            }
        }
    }

    private func heardFinal(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Lofer's own voice: while it talks, or just after (the tail of the echo).
        let recentLine = lastLine.flatMap { Date().timeIntervalSince($0.endedAt) < 2 ? $0.text : nil }
        if VoiceInterrupts.isEcho(text, of: currentLine ?? recentLine) { return }
        // The same words twice in quick succession: one utterance, delivered once.
        if let last = lastFinal, last.text == text, Date().timeIntervalSince(last.at) < 2 { return }
        lastFinal = (text, Date())
        let urgent = VoiceInterrupts.isUrgent(text)
        if state == .speaking, urgent || bargeIn { cutIn() }
        if handling && !urgent {
            queued.append(text)               // its turn comes when the app has handled the last one
            return
        }
        deliver(text)                         // urgent words never wait behind anything
    }

    // MARK: - Helpers

    private func deliver(_ text: String) {
        handling = true
        if state != .speaking { state = .thinking }
        handlingTask?.cancel()
        handlingTask = Task { [weak self, handlingTimeout] in
            try? await Task.sleep(for: handlingTimeout)
            guard let self, !Task.isCancelled, handling else { return }
            transcriptHandled()
        }
        onTranscript?(text, true)
    }

    private var restingState: VoiceState { handling ? .thinking : handsFree ? .listening : .idle }

    private func stopSpeaking() {
        speakTask?.cancel(); speakTask = nil
        synthesizer.stop()
        if let line = currentLine { lastLine = (line, Date()) }
        currentLine = nil
    }

    /// The user talked over Lofer: stop the audio and listen.
    private func cutIn() {
        guard state == .speaking, !cutOff else { return }
        cutOff = true
        stopSpeaking()
        state = handling ? .thinking : .listening
    }

    private func finishedSpeaking() {
        if let line = currentLine { lastLine = (line, Date()) }
        currentLine = nil; speakTask = nil
        if state == .speaking { state = restingState }
        restartIdleTimer()
    }

    private func fail(_ problem: VoiceProblem) {
        handsFree = false
        startTask?.cancel(); startTask = nil
        idleTask?.cancel()
        recognizer.stop()
        self.problem = problem
        if state != .speaking { state = .error }
    }

    private func restartIdleTimer() {
        idleTask?.cancel()
        guard handsFree else { return }
        idleTask = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard let self, !Task.isCancelled, handsFree, state == .listening else { return }
            stopListening()
        }
    }

    @ObservationIgnored private var resumeAfterInterruption = false
    private func audioInterrupted(began: Bool) {
        if began {
            resumeAfterInterruption = handsFree
            stopSpeaking()
            if handsFree { stopListening() }
            if state == .speaking { state = .idle }
        } else if resumeAfterInterruption {
            resumeAfterInterruption = false
            startListening()
        }
    }
}
