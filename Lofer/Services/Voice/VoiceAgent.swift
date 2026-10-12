import Foundation
import Observation

/// Voice states shared by every provider.
enum VoiceState: String { case idle = "IDLE", listening = "LISTENING", thinking = "THINKING", speaking = "SPEAKING", interrupted = "INTERRUPTED", error = "ERROR" }

/// VOICE — provider-independent. Voice is an input method for the whole app
/// (body selection, assessment, movement check, treatment, reassessment), not a chat screen.
/// It never controls hardware: transcripts go to the care flow, which turns them into
/// structured intents for the engine and safety layer.
///
///   VoiceAgent
///   ├── MockVoiceAgent          ← typed / sample text stands in for speech (default)
///   └── ElevenLabsVoiceAgent    ← real speech: ElevenLabs speech-to-text + text-to-speech via
///                                  Lofer's backend (no keys in the app). See ElevenLabsVoiceAgent.swift.
///
/// The app (AppModel, CareFlowModel) only ever talks to this protocol, so providers are
/// interchangeable: VoiceConfig picks one at launch (-LoferVoice mock|elevenlabs) and nothing
/// else changes. Providers must be `Observable` so screens update when `state` changes.
/// Everything runs on the main actor, like the screens and the care flow that use it.
@MainActor
protocol VoiceAgent: AnyObject, Observable {
    var state: VoiceState { get }
    /// True when the provider listens through the microphone. False for the mock, where a
    /// text field stands in for speech.
    var usesMicrophone: Bool { get }
    /// Why voice isn't working right now (e.g. microphone access denied), for the screen to show.
    var problem: VoiceProblem? { get }
    /// Called with what was heard: (text, isFinal). Partial results may arrive first.
    var onTranscript: ((String, Bool) -> Void)? { get set }
    func startListening()
    func stopListening()
    /// Text that didn't come from the microphone (typed, or a tapped suggestion). It is
    /// delivered through `onTranscript` like speech, so the care flow treats taps, typing
    /// and talking the same. `replay: .asSpeech` lets a provider show it arriving word by
    /// word as if spoken (the mock does; a real provider may just deliver it).
    func submitText(_ text: String, replay: TextReplay)
    func speak(_ text: String)
    func interrupt()
    /// The app has finished handling the last transcript. If Lofer isn't saying anything,
    /// the provider goes back from "thinking" to idle.
    func transcriptHandled()
}

extension VoiceAgent {
    var usesMicrophone: Bool { false }
    var problem: VoiceProblem? { nil }
}

/// Why voice can't be used right now. Typing always still works.
enum VoiceProblem: Error, Equatable {
    case microphoneDenied        // the user said no to microphone access (Settings › Lofer to change)
    case microphoneUnavailable   // no microphone input (e.g. in use by a call)
    case notConfigured           // the backend refused the app (missing or wrong client key)
    case unavailable             // the backend or the speech service can't be reached
    case connectionLost          // the live transcription connection dropped

    /// Short enough for the label under the voice orb.
    var message: String {
        switch self {
        case .microphoneDenied: "Microphone is off for Lofer. Type instead, or allow it in Settings."
        case .microphoneUnavailable: "The microphone isn't available right now. Type instead."
        case .notConfigured: "Voice isn't set up on this build. Type instead."
        case .unavailable, .connectionLost: "Voice isn't reachable right now. Type instead, or tap to retry."
        }
    }
    /// For the small label next to the orb during care.
    var shortLabel: String { self == .microphoneDenied ? "Mic off · type instead" : "Voice unavailable" }
}

/// How submitted text is presented while it's delivered.
enum TextReplay {
    case instant    // straight to a final transcript
    case asSpeech   // may arrive word by word first, like live speech (demo, suggestions)
}

/// Prototype provider: no microphone, no audio. While LISTENING the UI shows a text
/// field; whatever is submitted becomes the transcript. speak() holds the SPEAKING
/// state for about as long as the line would take to say.
@Observable
final class MockVoiceAgent: VoiceAgent {
    private(set) var state: VoiceState = .idle
    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    @ObservationIgnored private var simTask: Task<Void, Never>?

    func startListening() { if state == .speaking { interrupt() }; state = .listening }
    func stopListening() { if state == .listening { state = .idle } }
    func submitText(_ text: String, replay: TextReplay) {
        switch replay {
        case .instant: deliverFinal(text)
        case .asSpeech: replayAsSpeech(text)
        }
    }
    private func deliverFinal(_ input: String) {
        simTask?.cancel()
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { state = .idle; return }
        state = .thinking
        onTranscript?(t, true)
    }
    /// Shows the text arriving word by word, as if spoken, then delivers it as final.
    private func replayAsSpeech(_ text: String) {
        startListening()
        simTask?.cancel()
        simTask = Task { @MainActor in
            var acc = ""
            for (i, w) in text.split(separator: " ").enumerated() {
                try? await Task.sleep(for: .milliseconds(140))
                if Task.isCancelled || state != .listening { return }
                acc += (i == 0 ? "" : " ") + w
                onTranscript?(acc, false)
            }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            deliverFinal(text)
        }
    }
    func speak(_ text: String) {
        speakTask?.cancel()
        state = .speaking
        let ms = min(2600, 500 + text.count * 30)
        speakTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(ms))
            if !Task.isCancelled, state == .speaking { state = .idle }
        }
    }
    func interrupt() { speakTask?.cancel(); state = .interrupted; Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); if state == .interrupted { state = .idle } } }
    func transcriptHandled() { if state == .thinking { state = .idle } }
}
