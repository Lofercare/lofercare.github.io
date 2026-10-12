import Foundation

/// Which voice provider this build uses.
///
///   mock        typed / sample text stands in for speech (default; no network, no microphone)
///   elevenlabs  real speech: ElevenLabs speech-to-text + text-to-speech through Lofer's backend
///
/// Choose with launch arguments (Xcode: Product › Scheme › Edit Scheme › Arguments):
///   -LoferVoice mock|elevenlabs            (or the LOFER_VOICE environment variable)
///   -LoferVoiceBargeIn off                 talking over Lofer no longer cuts it off ("stop" still does)
/// The backend address is the same as Care Intelligence's (-LoferBackendURL), and so is the
/// client key (LOFER_CLIENT_KEY, set only in your local scheme: never commit it).
struct VoiceConfig: Equatable {
    enum Mode: String { case mock, elevenlabs }
    var mode: Mode
    var backendURL: URL
    var clientKey: String?
    var bargeIn = true

    static func fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments,
                                    environment env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        func value(_ name: String, env envName: String) -> String? {
            if let i = args.firstIndex(of: "-\(name)"), i + 1 < args.count { return args[i + 1] }
            return env[envName]
        }
        let care = CareIntelligenceConfig.fromLaunchArguments(args, environment: env)
        return .init(mode: value("LoferVoice", env: "LOFER_VOICE").flatMap(Mode.init(rawValue:)) ?? .mock,
                     backendURL: care.backendURL, clientKey: care.clientKey,
                     bargeIn: value("LoferVoiceBargeIn", env: "LOFER_VOICE_BARGE_IN") != "off")
    }

    @MainActor func makeAgent() -> any VoiceAgent {
        switch mode {
        case .mock: return MockVoiceAgent()
        case .elevenlabs:
            let backend = VoiceBackendClient(baseURL: backendURL, clientKey: clientKey)
            let audio = VoiceAudioEngine()
            return ElevenLabsVoiceAgent(recognizer: ScribeRealtimeRecognizer(backend: backend, audio: audio),
                                        synthesizer: BackendSpeechSynthesizer(backend: backend, audio: audio),
                                        bargeIn: bargeIn)
        }
    }
}
