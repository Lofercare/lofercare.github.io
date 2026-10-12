import SwiftUI
import Observation

/// App-wide state: which screen is showing, page navigation, and the shared services.
/// Mock services are created HERE — swapping in real ones later (LLM, ElevenLabs,
/// physical device) is a one-line change in this file.
@Observable @MainActor
final class AppModel {
    enum Screen { case splash, home, care }
    enum Page: Hashable { case history, episode(String), report(String?), profile, typography }

    var screen: Screen = .splash
    var path: [Page] = []

    // Shared services. `voice` is any VoiceAgent: the mock now, a real provider later.
    let memory: BodyMemoryStore
    let voice: any VoiceAgent
    let device: DeviceInterface = MockLoferDevice()
    /// Care Intelligence: Lofer's backend in Debug builds (POST /api/care, run `npm start` in
    /// backend/), with the on-device service as fallback. See CareIntelligenceConfig.
    let intelligence: CareIntelligenceService
    let body = BodySceneController()
    @ObservationIgnored private(set) lazy var care: CareFlowModel = {
        let c = CareFlowModel(memory: memory, intelligence: intelligence, device: device, voice: voice, body: body)
        c.onExit = { [weak self] in self?.goHome() }
        c.onOpenReport = { [weak self] g in self?.goHome(); self?.path = [.report(g)] }
        return c
    }()

    // Home screen state
    var homeLine = "How is your body feeling today?"
    var homeHeard = ""
    var homeContext = ""
    var input = InputState()

    struct InputState { var visible = false; var voiceMode = false; var suggestion: String? }

    static let greetings = ["How is your body feeling today?", "Tell me what’s been going on and how you’re feeling.", "Anything bothering you today?"]
    static let homeSamples = [AppModel.investigationStory, "The back of my left knee is sore after my run.",
                              "My lower back is stiff from sitting all day.", "My wrist feels weird after working all day."]
    @ObservationIgnored private var sampleIndex = 0
    static let investigationStory = "I played tennis for two hours yesterday. The back of my right shoulder started feeling tight afterwards. It's mostly okay normally but hurts a little when I lift my arm above my head."
    /// The pending "heard you → act on it" step. Cancelled when newer input arrives or the user leaves.
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?

    /// The voice provider is chosen here (default: the mock; LoferApp passes VoiceConfig's choice).
    /// Pass another VoiceAgent, CareIntelligenceService or memory store to swap them (tests do).
    init(voice: (any VoiceAgent)? = nil,
         intelligence: CareIntelligenceService = CareIntelligenceConfig.fromLaunchArguments().makeService(),
         memory: BodyMemoryStore? = nil) {
        let voice = voice ?? MockVoiceAgent()
        self.voice = voice
        self.intelligence = intelligence
        self.memory = memory ?? BodyMemoryStore()
        voice.onTranscript = { [weak self] text, final in
            Task { @MainActor in self?.transcript(text, final: final) }
        }
        _ = care
        // Demo modes for screenshots/testing (Xcode: Product › Scheme › Edit Scheme › Arguments):
        //   -LoferDemo      plays a sample story
        //   -LoferDemoFull  plays a whole conversation, through the movement check to treatment
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-LoferDemo") || args.contains("-LoferDemoFull") {
            self.memory.samplesInformDecisions = true   // the demo story relies on the sample history
            // The full demo follows one investigation: story → confirm the spot → movement
            // check → observation → summary → suggestion → session.
            let script: [(Double, String)] = args.contains("-LoferDemoFull")
                ? [(5, Self.investigationStory), (8, "Yes, that's it."), (7, "It starts pulling about halfway."),
                   (7, "Yes, it eased straight away."), (7, "Yes, that's right."), (7, "Okay, let's start.")]
                : [(5, Self.homeSamples[0])]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4)); self.screen = .home
                for (wait, line) in script { try? await Task.sleep(for: .seconds(wait)); self.voice.submitText(line, replay: .asSpeech) }
            }
        }
    }

    // MARK: navigation
    func finishSplash() { if screen == .splash { withAnimation(Motion.slow) { screen = .home } } }
    func goHome() { dropPendingTranscript(); care.reset(); input.visible = false; homeHeard = ""; homeContext = ""; homeLine = Self.greetings[0]; withAnimation(Motion.slow) { screen = .home } }
    func openBody() { dropPendingTranscript(); care.beginWithBody(); withAnimation(Motion.slow) { screen = .care } }
    func treatAgain(_ e: Episode) {
        path = []
        dropPendingTranscript()
        care.beginWithBody()
        withAnimation(Motion.slow) { screen = .care }
        Task { await care.applyTarget(.id(e.symptom.areaId)) }
    }

    // MARK: voice + typing (both end up as a transcript)
    /// Mic button: start listening, stop, or interrupt Lofer. With the mock there's no
    /// microphone, so a text field (plus a suggestion) stands in for speech. With real voice,
    /// listening is hands-free: it stays on after Lofer answers, until the mic is tapped again.
    func micTapped() {
        if voice.state == .listening { voice.stopListening(); input.visible = false; return }
        voice.startListening()
        input = voice.usesMicrophone ? InputState() : InputState(visible: true, voiceMode: true, suggestion: suggestion())
    }
    /// Switching to typing turns the microphone off.
    func keyboardTapped() {
        if voice.usesMicrophone { voice.stopListening() }
        input = InputState(visible: true, voiceMode: false, suggestion: nil)
    }
    func submitTyped(_ text: String) { input.visible = false; voice.submitText(text, replay: .instant) }
    func useSuggestion() { if let s = input.suggestion { input.visible = false; voice.submitText(s, replay: .asSpeech) } }
    func closeInput() { input.visible = false; voice.stopListening() }

    private func transcript(_ text: String, final: Bool) {
        if screen == .home { homeHeard = "“\(text)”" } else { care.heard = "“\(text)”" }
        guard final else { return }
        input.visible = false
        transcriptTask?.cancel()
        // A short pause first, so a quick correction replaces what was just said. Never for
        // "stop", "pause" or discomfort: those go to the care flow at once.
        let pause = VoiceInterrupts.isUrgent(text) ? 0 : 600
        transcriptTask = Task { @MainActor in
            if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
            guard !Task.isCancelled else { return }
            if screen == .home {
                // The story is told on the home screen; Lofer acknowledges, then the body takes over.
                let r = SymptomParser.parse(text)
                var probe = AssessmentState(); var learned = AssessmentService.update(&probe, with: r, expect: "story")
                if let e = r.entry, e.id != nil || r.side != nil { learned.append("region") }
                homeLine = AssessmentService.ack(probe, learned: learned).isEmpty ? "Thanks for telling me." : AssessmentService.ack(probe, learned: learned)
                homeContext = [SymptomParser.typeLabel(r.type).flatMap { r.type == "pain" ? nil : $0 }, r.activity.map { "after \($0)" }, r.onset].compactMap { $0 }.joined(separator: " · ")
                voice.speak(homeLine)
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled, screen == .home else { return }
                withAnimation(Motion.slow) { screen = .care }
                await care.beginWithStory(text)
            } else {
                await care.hear(text)
            }
            voice.transcriptHandled()
        }
    }

    /// Abandons the transcript still being acted on (the user left or started again), and tells
    /// the voice agent so it doesn't keep waiting for it.
    private func dropPendingTranscript() {
        guard let task = transcriptTask else { return }
        task.cancel(); transcriptTask = nil
        voice.transcriptHandled()
    }

    /// What the user would plausibly say next (offered as a one-tap suggestion while "listening").
    func suggestion() -> String {
        if screen == .home { defer { sampleIndex += 1 }; return Self.homeSamples[sampleIndex % Self.homeSamples.count] }
        let c = care
        if c.pendingSide != nil { return "The right one." }
        switch c.step {
        case .clarify:
            return ["story": "I played tennis yesterday and my shoulder has felt tight since.", "sensation": "It feels tight.", "triggers": "Mostly when I lift it above my head.",
                    "onset": "Since yesterday.", "severity": "Quite a lot.", "previous": "It’s happened before.", "safety": "No, none of those."][c.question?.field ?? ""]
                ?? (c.question?.field.hasPrefix("observation:") == true ? "Yes, it eased straight away." : "Okay.")
        case .locate, .listening: return c.sel != nil ? "Yes, that’s it." : !c.lit.isEmpty ? "It’s actually more towards the back." : "My right shoulder."
        case .confirm: return "Yes, that’s right."
        case .correct: return "It’s more on the outside, actually."
        case .movement: return c.movementPhase == "after" ? "It feels easier now." : "It starts pulling about halfway."
        case .suggest: return "Keep it gentle, and a bit more heat."
        case .custom: return "Okay, let’s start."
        case .treat: return c.checkIn ? "That’s a little too strong." : "Can you focus slightly lower?"
        case .paused: return "Carry on."
        case .reassess: return "It definitely feels looser now."
        default: return "Thanks."
        }
    }
}
