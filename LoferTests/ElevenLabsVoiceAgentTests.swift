import XCTest
import AVFoundation
@testable import Lofer

/// Phase 4: real voice. ElevenLabsVoiceAgent is driven through fake ears and a fake mouth,
/// so these tests run offline and never touch the microphone or ElevenLabs. The real
/// recognizer and synthesizer are checked separately (message formats, URLs) and live with
/// the backend smoke test.
@MainActor
final class ElevenLabsVoiceAgentTests: XCTestCase {

    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var finals: [String] = []
    private var partials: [String] = []

    private func makeAgent(bargeIn: Bool = true, idleTimeout: Duration = .seconds(120), notifications: NotificationCenter = .init()) -> ElevenLabsVoiceAgent {
        recognizer = FakeRecognizer(); synthesizer = FakeSynthesizer()
        finals = []; partials = []
        let agent = ElevenLabsVoiceAgent(recognizer: recognizer, synthesizer: synthesizer, bargeIn: bargeIn,
                                         idleTimeout: idleTimeout, notifications: notifications)
        agent.onTranscript = { [unowned self] text, final in if final { finals.append(text) } else { partials.append(text) } }
        return agent
    }
    private func listening(_ agent: ElevenLabsVoiceAgent) async throws {
        agent.startListening()
        try await waitUntil { agent.state == .listening && self.recognizer.running }
    }

    // MARK: - Session, permission, connection

    func testListeningStartsHandsFreeAndStops() async throws {
        let agent = makeAgent()
        XCTAssertTrue(agent.usesMicrophone)
        try await listening(agent)
        XCTAssertEqual(recognizer.starts, 1)
        agent.stopListening()
        XCTAssertEqual(agent.state, .idle)
        XCTAssertFalse(recognizer.running, "The microphone is off")
        recognizer.emit(.final("Something said after stopping."))
        XCTAssertTrue(finals.isEmpty, "Nothing is heard once listening is off")
    }

    func testMicrophoneDeniedShowsTheProblemAndTypingStillWorks() async throws {
        let agent = makeAgent()
        recognizer.startError = VoiceProblem.microphoneDenied
        agent.startListening()
        try await waitUntil { agent.state == .error }
        XCTAssertEqual(agent.problem, .microphoneDenied)
        agent.submitText("My right shoulder is tight.", replay: .instant)
        XCTAssertEqual(finals, ["My right shoulder is tight."])
        recognizer.startError = nil
        agent.startListening()
        XCTAssertNil(agent.problem, "Trying again clears the problem")
    }

    func testADroppedConnectionReconnectsOnce() async throws {
        let agent = makeAgent()
        try await listening(agent)
        recognizer.emit(.failed(.connectionLost))
        try await waitUntil { self.recognizer.starts == 2 && agent.state == .listening }
        XCTAssertNil(agent.problem)
    }

    func testAFailedReconnectReportsAProblem() async throws {
        let agent = makeAgent()
        try await listening(agent)
        recognizer.startError = VoiceProblem.unavailable
        recognizer.emit(.failed(.connectionLost))
        try await waitUntil { agent.state == .error }
        XCTAssertEqual(agent.problem, .unavailable)
        XCTAssertFalse(recognizer.running)
    }

    func testIdleListeningTurnsItselfOff() async throws {
        let agent = makeAgent(idleTimeout: .milliseconds(150))
        try await listening(agent)
        try await waitUntil { agent.state == .idle }
        XCTAssertFalse(recognizer.running)
    }

    func testAPhoneCallStopsListeningAndItResumesAfterwards() async throws {
        let center = NotificationCenter()
        let agent = makeAgent(notifications: center)
        try await listening(agent)
        func post(_ type: AVAudioSession.InterruptionType) {
            center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }
        post(.began)
        XCTAssertEqual(agent.state, .idle)
        XCTAssertFalse(recognizer.running)
        post(.ended)
        try await waitUntil { self.recognizer.running && agent.state == .listening }
    }

    // MARK: - Transcripts: only finals, each once, in order

    func testOnlyFinalTranscriptsAreSubmittedAndEachOnlyOnce() async throws {
        let agent = makeAgent()
        try await listening(agent)
        recognizer.emit(.partial("My right"))
        recognizer.emit(.partial("My right shoulder"))
        XCTAssertTrue(finals.isEmpty, "Partials only show what's being heard")
        recognizer.emit(.final("My right shoulder is tight."))
        recognizer.emit(.final("My right shoulder is tight."))   // the same utterance reported twice
        XCTAssertEqual(partials, ["My right", "My right shoulder"])
        XCTAssertEqual(finals, ["My right shoulder is tight."])
        XCTAssertEqual(agent.state, .thinking)
        agent.transcriptHandled()
        XCTAssertEqual(agent.state, .listening, "Hands-free: back to listening")
    }

    func testWhatIsSaidWhileLoferIsThinkingWaitsItsTurn() async throws {
        let agent = makeAgent()
        try await listening(agent)
        recognizer.emit(.final("It's my right shoulder."))
        recognizer.emit(.final("Mostly when I lift it."))
        XCTAssertEqual(finals, ["It's my right shoulder."], "Not sent while the first is still being handled")
        agent.transcriptHandled()
        XCTAssertEqual(finals, ["It's my right shoulder.", "Mostly when I lift it."], "…and not lost either")
        agent.transcriptHandled()
        XCTAssertEqual(finals.count, 2)
    }

    // MARK: - Speaking, interruption, echo

    func testLoferSpeaksExactlyTheLineItIsGiven() async throws {
        let agent = makeAgent()
        try await listening(agent)
        agent.speak("Show me where it's bothering you.")
        XCTAssertEqual(agent.state, .speaking)
        try await waitUntil { self.synthesizer.spoken == ["Show me where it's bothering you."] }
        synthesizer.finishLine()
        try await waitUntil { agent.state == .listening }
    }

    func testStopWhileLoferIsTalkingCutsTheAudioAtOnce() async throws {
        let agent = makeAgent()
        try await listening(agent)
        recognizer.emit(.final("Okay, let's start."))                // still being handled
        agent.speak("Starting now. Tell me if anything feels too strong.")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("stop"))
        XCTAssertNil(synthesizer.playing, "Audio stops on the partial, before the sentence is even finished")
        XCTAssertNotEqual(agent.state, .speaking)
        XCTAssertEqual(recognizer.commits, 1, "…and the utterance is finished early")
        recognizer.emit(.final("Stop."))
        XCTAssertEqual(finals, ["Okay, let's start.", "Stop."], "Urgent words never wait behind anything")
    }

    func testDiscomfortCutsTheAudioEvenWithBargeInOff() async throws {
        let agent = makeAgent(bargeIn: false)
        try await listening(agent)
        agent.speak("Let's begin with some gentle heat on your right shoulder.")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("it's getting quite"))
        XCTAssertNotNil(synthesizer.playing, "Barge-in is off: ordinary speech doesn't cut Lofer off")
        recognizer.emit(.partial("it's getting quite painful"))
        XCTAssertNil(synthesizer.playing)
    }

    func testTalkingOverLoferCutsItOffWhenBargeInIsOn() async throws {
        let agent = makeAgent()
        try await listening(agent)
        agent.speak("Can you lift your arm slowly above your head?")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("it's actually"))
        XCTAssertNil(synthesizer.playing)
        XCTAssertEqual(agent.state, .listening)
    }

    func testLofersOwnVoiceIsNotHeardAsTheUser() async throws {
        let agent = makeAgent()
        try await listening(agent)
        agent.speak("Before we go on: any numbness, tingling, swelling or weakness?")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("any numbness tingling"))
        recognizer.emit(.final("Any numbness, tingling, swelling or weakness?"))
        XCTAssertNotNil(synthesizer.playing, "Its own words don't cut it off")
        XCTAssertTrue(finals.isEmpty, "…and are never reported as the user's warning signs")
    }

    func testASingleUrgentWordIsNeverMistakenForEcho() async throws {
        let agent = makeAgent()
        try await listening(agent)
        agent.speak("You can say too strong, move the focus lower, or stop.")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("stop"))
        XCTAssertNil(synthesizer.playing, "If in doubt, stop")
    }

    func testTypingWhileLoferTalksStopsTheAudio() async throws {
        let agent = makeAgent()
        agent.speak("Show me where it's bothering you.")
        try await waitUntil { self.synthesizer.playing != nil }
        agent.submitText("My left calf.", replay: .instant)
        XCTAssertNil(synthesizer.playing)
        XCTAssertEqual(finals, ["My left calf."])
    }

    func testTappingTheOrbInterrupts() async throws {
        let agent = makeAgent()
        agent.speak("A long explanation.")
        try await waitUntil { self.synthesizer.playing != nil }
        agent.interrupt()
        XCTAssertEqual(agent.state, .interrupted)
        XCTAssertNil(synthesizer.playing)
        try await waitUntil { agent.state == .idle }
    }

    // MARK: - Small pieces

    func testUrgentAndEchoRules() {
        XCTAssertTrue(VoiceInterrupts.isUrgent("Stop."))
        XCTAssertTrue(VoiceInterrupts.isUrgent("hold on a second"))
        XCTAssertTrue(VoiceInterrupts.isUrgent("that's too strong"))
        XCTAssertTrue(VoiceInterrupts.isUrgent("ouch, that hurts"))
        XCTAssertFalse(VoiceInterrupts.isUrgent("it starts pulling about halfway"))
        XCTAssertFalse(VoiceInterrupts.isUrgent("stopwatch"), "Whole words only")
        XCTAssertTrue(VoiceInterrupts.isEcho("how did that feel", of: "How did that feel?"))
        XCTAssertFalse(VoiceInterrupts.isEcho("yes some tingling", of: "Any numbness or tingling?"))
        XCTAssertFalse(VoiceInterrupts.isEcho("anything", of: nil))
    }

    func testScribeMessagesBecomeEvents() {
        XCTAssertEqual(ScribeRealtimeRecognizer.event(from: #"{"message_type":"session_started","session_id":"s1","config":{}}"#), .started)
        XCTAssertEqual(ScribeRealtimeRecognizer.event(from: #"{"message_type":"partial_transcript","text":"my right"}"#), .partial("my right"))
        XCTAssertEqual(ScribeRealtimeRecognizer.event(from: #"{"message_type":"committed_transcript","text":" My right shoulder. "}"#), .final("My right shoulder."))
        XCTAssertNil(ScribeRealtimeRecognizer.event(from: #"{"message_type":"committed_transcript","text":""}"#), "Silence isn't an utterance")
        XCTAssertNil(ScribeRealtimeRecognizer.event(from: #"{"message_type":"insufficient_audio_activity"}"#))
        XCTAssertEqual(ScribeRealtimeRecognizer.event(from: #"{"message_type":"auth_error","error":"bad token"}"#), .failed(.unavailable))
        XCTAssertEqual(ScribeRealtimeRecognizer.event(from: #"{"message_type":"session_time_limit_exceeded"}"#), .failed(.connectionLost))
        XCTAssertNil(ScribeRealtimeRecognizer.event(from: "not json"))
    }

    func testScribeConnectionAndAudioMessageFormat() throws {
        let url = ScribeRealtimeRecognizer.url(token: "sutkn_abc")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["token"], "sutkn_abc", "A single-use token, never the API key")
        XCTAssertEqual(query["model_id"], "scribe_v2_realtime")
        XCTAssertEqual(query["audio_format"], "pcm_16000")
        XCTAssertEqual(query["commit_strategy"], "vad")

        let json = AudioChunkSender.message(Data([1, 2, 3, 4]), commit: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["audio_base_64"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
        XCTAssertEqual(object["commit"] as? Bool, true)
        XCTAssertEqual(object["sample_rate"] as? Int, 16000)
    }

    func testSpeechAudioIsConvertedForPlayback() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        var samples: [Int16] = [0, 16384, -32768]
        let buffer = try XCTUnwrap(VoiceAudioEngine.floatBuffer(from: Data(bytes: &samples, count: 6), format: format))
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.floatChannelData![0][1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(buffer.floatChannelData![0][2], -1, accuracy: 0.0001)
    }

    func testVoiceProviderIsChosenByConfiguration() {
        XCTAssertEqual(VoiceConfig.fromLaunchArguments([], environment: [:]).mode, .mock, "Mock by default")
        let real = VoiceConfig.fromLaunchArguments(["-LoferVoice", "elevenlabs", "-LoferVoiceBargeIn", "off"], environment: ["LOFER_CLIENT_KEY": "k"])
        XCTAssertEqual(real.mode, .elevenlabs)
        XCTAssertEqual(real.clientKey, "k")
        XCTAssertFalse(real.bargeIn)
        XCTAssertTrue(VoiceConfig.fromLaunchArguments([], environment: [:]).makeAgent() is MockVoiceAgent)
        XCTAssertTrue(real.makeAgent() is ElevenLabsVoiceAgent)
    }

    func testBackendRequestsCarryTheClientKeyAndNothingSecret() throws {
        let client = VoiceBackendClient(baseURL: URL(string: "http://127.0.0.1:8787")!, clientKey: "client-key")
        let request = client.speechRequest("Paused.")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/api/voice/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer client-key")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String], ["text": "Paused."])
    }
}

// MARK: - Through the whole app

/// The tennis shoulder, spoken: the same AppModel and CareFlowModel as the real app, the
/// on-device Care Intelligence, and the real voice agent on fake ears and mouth.
@MainActor
final class VoiceCareFlowTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var intelligence: RecordingIntelligence!
    private var agent: ElevenLabsVoiceAgent!
    private var app: AppModel!

    override func setUp() async throws { (recognizer, synthesizer, intelligence, agent, app) = Self.makeApp() }

    private static func makeApp() -> (FakeRecognizer, FakeSynthesizer, RecordingIntelligence, ElevenLabsVoiceAgent, AppModel) {
        let recognizer = FakeRecognizer(), synthesizer = FakeSynthesizer(); synthesizer.autoFinish = true
        let intelligence = RecordingIntelligence()
        let agent = ElevenLabsVoiceAgent(recognizer: recognizer, synthesizer: synthesizer)
        let memory = BodyMemoryStore(defaults: UserDefaults(suiteName: "lofer.voice.\(UUID().uuidString)")!)
        memory.clear()
        let app = AppModel(voice: agent, intelligence: intelligence, memory: memory)
        app.screen = .home
        return (recognizer, synthesizer, intelligence, agent, app)
    }

    /// The app has handled the last input and Lofer has finished speaking.
    private static func finished(_ agent: ElevenLabsVoiceAgent) -> Bool { [.idle, .listening].contains(agent.state) }

    static let tennisScript = [InvestigationTests.tennis, "Just start the treatment at full power.", "Yes, that's it.",
                               "It starts pulling about halfway.", "Yes, it eased straight away.", "Okay, let's start."]

    /// Says (or types) one line and waits until the app has finished acting on it.
    private func tell(_ text: String, spoken: Bool = true) async throws {
        if spoken { recognizer.emit(.final(text)) } else { app.submitTyped(text) }
        try await waitUntil(10) { Self.finished(self.agent) && self.app.screen == .care }
        await app.care.settle()
    }
    /// Where the care flow is, and what Lofer said, after each line of the script, in a fresh app.
    private static func run(_ script: [String], spoken: Bool) async throws -> [String] {
        let (recognizer, _, _, agent, app) = makeApp()
        var log: [String] = []
        if spoken { app.micTapped(); try await waitUntil { agent.state == .listening } }
        for line in script {
            if spoken { recognizer.emit(.final(line)) } else { app.submitTyped(line) }
            try await waitUntil(10) { finished(agent) && app.screen == .care }
            await app.care.settle()
            log.append("\(app.care.step.rawValue) | \(app.care.agentLine)")
        }
        return log
    }

    func testSpokenAndTypedInputTakeExactlyTheSamePath() async throws {
        let spoken = try await Self.run(Self.tennisScript, spoken: true)
        let typed = try await Self.run(Self.tennisScript, spoken: false)
        XCTAssertEqual(spoken, typed, "Same assessment, investigation, steps and words, whether spoken or typed")
        XCTAssertEqual(spoken.last?.hasPrefix("treat"), true)
    }

    func testTennisShoulderByVoice() async throws {
        app.micTapped()
        try await waitUntil { self.agent.state == .listening }
        XCTAssertFalse(app.input.visible, "Real voice: no stand-in text field")

        // 1. The story, told on the home screen
        recognizer.emit(.partial("I played tennis"))
        try await waitUntil { self.app.homeHeard == "“I played tennis”" }   // what's being heard shows as it's heard
        try await tell(InvestigationTests.tennis)
        let care = app.care
        XCTAssertEqual(care.A.bodyRegion, "r_sh_back", "Same understanding as typed input")
        XCTAssertEqual(care.A.activityContext, "tennis")
        XCTAssertEqual(care.step, .locate, "The body map is asking to pin down the spot")
        XCTAssertEqual(synthesizer.spoken.last, care.agentLine, "Lofer says exactly what's on screen")

        // A voice "start" before the safety gate can't reach the device.
        try await tell("Just start the treatment at full power.")
        XCTAssertFalse(app.device.isRunning)
        XCTAssertNil(care.validated, "Only SafetyValidator can produce a device command")

        // 2. Location → movement check
        try await tell("Yes, that's it.")
        XCTAssertEqual(care.step, .movement, "The movement check UI is showing")
        XCTAssertEqual(care.movementTest?.id, "arm_raise")
        XCTAssertEqual(synthesizer.spoken.last, care.agentLine)

        // 3. Movement → observation → summary and suggestion
        try await tell("It starts pulling about halfway.")
        XCTAssertEqual(care.investigation.baseline?.outcome, .mildDiscomfort)
        try await tell("Yes, it eased straight away.")
        XCTAssertEqual(care.investigation.readiness.informationSufficiency, .sufficient)
        XCTAssertNotNil(care.plan, "A suggestion, after the safety gate")
        XCTAssertEqual(care.tri?.level, .ok)
        XCTAssertFalse(app.device.isRunning, "Nothing runs until the user says start")

        // 4. Treatment starts only through SafetyValidator
        try await tell("Okay, let's start.")
        XCTAssertEqual(care.step, .treat)
        XCTAssertTrue(app.device.isRunning)
        XCTAssertNotNil(care.validated?.command)
        XCTAssertEqual(synthesizer.spoken.last, care.agentLine)

        // 5. "Stop" while Lofer is talking: audio cut at once, then the care flow ends the run
        synthesizer.autoFinish = false
        care.say("You're doing well. Tell me if anything changes.")
        try await waitUntil { self.synthesizer.playing != nil }
        recognizer.emit(.partial("stop"))
        XCTAssertNil(synthesizer.playing, "Audio stopped on the partial")
        synthesizer.autoFinish = true
        try await tell("Stop.")
        XCTAssertFalse(app.device.isRunning, "Stopped through the care flow's own logic")
        XCTAssertEqual(care.step, .movement, "Same movement again, after care")

        // Every utterance reached Care Intelligence at most once (no duplicates).
        let sent = intelligence.utterances
        XCTAssertEqual(sent.count, Set(sent).count, "Duplicate submissions: \(sent)")
    }

    func testTypingAndVoiceShareThePipelineAndSwitchCleanly() async throws {
        app.micTapped()
        try await waitUntil { self.agent.state == .listening }
        app.keyboardTapped()
        XCTAssertFalse(recognizer.running, "Typing turns the microphone off")
        XCTAssertTrue(app.input.visible)
        app.submitTyped(InvestigationTests.tennis)
        try await waitUntil(10) { self.app.screen == .care && Self.finished(self.agent) }
        XCTAssertEqual(app.care.A.bodyRegion, "r_sh_back", "Typed text takes the same path as speech")
        XCTAssertEqual(intelligence.utterances, [InvestigationTests.tennis])
    }

    func testMockModeStillUsesTheTextField() {
        let mockApp = AppModel(intelligence: LocalCareIntelligenceService(),
                               memory: BodyMemoryStore(defaults: UserDefaults(suiteName: "lofer.voice.\(UUID().uuidString)")!))
        XCTAssertTrue(mockApp.voice is MockVoiceAgent)
        mockApp.screen = .home
        mockApp.micTapped()
        XCTAssertTrue(mockApp.input.visible)
        XCTAssertNotNil(mockApp.input.suggestion)
    }
}

// MARK: - Fakes

@MainActor
final class FakeRecognizer: SpeechRecognitionService {
    var onEvent: ((SpeechRecognitionEvent) -> Void)?
    var startError: Error?
    private(set) var starts = 0, commits = 0
    private(set) var running = false
    func start() async throws {
        starts += 1
        if let startError { throw startError }
        running = true
        onEvent?(.started)
    }
    func stop() { running = false }
    func commitNow() { commits += 1 }
    func emit(_ event: SpeechRecognitionEvent) { onEvent?(event) }
}

@MainActor
final class FakeSynthesizer: SpeechSynthesisService {
    private(set) var spoken: [String] = []
    private(set) var playing: String?
    var autoFinish = false
    private var finish: CheckedContinuation<Void, Error>?
    func speak(_ text: String) async throws {
        spoken.append(text)
        if autoFinish { return }
        playing = text
        try await withCheckedThrowingContinuation { finish = $0 }
    }
    func finishLine() { playing = nil; finish?.resume(); finish = nil }
    func stop() { playing = nil; finish?.resume(throwing: CancellationError()); finish = nil }
}

/// The on-device Care Intelligence, recording every utterance it's asked about.
final class RecordingIntelligence: CareIntelligenceService, @unchecked Sendable {
    private(set) var utterances: [String] = []
    func respond(to request: CareRequest) async throws -> CareIntelligenceResponse {
        if request.latestUserInput.kind == .utterance, let t = request.latestUserInput.text { utterances.append(t) }
        return LocalCareIntelligenceService.response(to: request)
    }
}

@MainActor
func waitUntil(_ seconds: Double = 3, _ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { XCTFail("Timed out waiting", file: file, line: line); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}
