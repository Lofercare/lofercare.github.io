import Foundation

/// The two halves of real speech, kept separate so each can be swapped or faked in tests:
///
///   ElevenLabsVoiceAgent (the VoiceAgent the app talks to)
///   ├── SpeechRecognitionService   ears:  microphone → text   (ScribeRealtimeRecognizer)
///   └── SpeechSynthesisService     mouth: text → speaker      (BackendSpeechSynthesizer)
///
/// Neither half understands anything or decides anything. Recognized text goes to the care
/// flow like typed text; the only text ever spoken is the line the care flow shows on screen.

/// What the recognizer reports while it listens.
enum SpeechRecognitionEvent: Equatable {
    case started                  // connected; the microphone is streaming
    case partial(String)          // what's been heard so far of the current utterance (may change)
    case final(String)            // a finished utterance: this is what goes to the care flow
    case failed(VoiceProblem)     // stopped listening because of a problem
}

@MainActor
protocol SpeechRecognitionService: AnyObject {
    var onEvent: ((SpeechRecognitionEvent) -> Void)? { get set }
    /// Microphone permission → backend token → live transcription. Throws a `VoiceProblem`.
    func start() async throws
    func stop()
    /// Finish the current utterance now, without waiting for the user to go quiet
    /// (used when they say "stop" or "that hurts", so it reaches the care flow sooner).
    func commitNow()
}

@MainActor
protocol SpeechSynthesisService: AnyObject {
    /// Speaks one complete line. Returns when it has finished playing; throws if it was
    /// stopped or failed.
    func speak(_ text: String) async throws
    /// Stops speaking immediately (an interruption, or a newer line).
    func stop()
}
