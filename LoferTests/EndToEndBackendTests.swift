import XCTest
import Observation
@testable import Lofer

/// END TO END: the real care flow + the LOCAL Lofer backend (MockCareIntelligenceProvider) +
/// MockLoferDevice, from the tennis story through to Body Memory.
///
/// Needs the backend running:  cd backend && npm start
/// Skipped (not failed) when it isn't, so the normal test run stays offline.
@MainActor
final class EndToEndBackendTests: XCTestCase {
    static let backend = URL(string: ProcessInfo.processInfo.environment["LOFER_BACKEND_URL"] ?? "http://127.0.0.1:8787")!
    /// The backend's LOFER_CLIENT_KEY, when it requires one. Pass it to `xcodebuild test` as
    /// TEST_RUNNER_LOFER_CLIENT_KEY=… (xcodebuild hands TEST_RUNNER_ variables to the tests).
    static let clientKey = ProcessInfo.processInfo.environment["LOFER_CLIENT_KEY"]

    /// The mock provider's exact script (deterministic, so every step is checked).
    func testTennisSessionThroughTheLocalBackend() async throws {
        let provider = try await skipUnlessBackendIsUp()
        try XCTSkipUnless(provider == "mock", "This scripted test is for the mock provider (running: \(provider))")
        let voice = TranscriptVoice()
        let memory = BodyMemoryStore(defaults: UserDefaults(suiteName: "lofer.e2e.\(UUID().uuidString)")!)
        memory.clear()
        let device = MockLoferDevice()
        let m = CareFlowModel(memory: memory, intelligence: APICareIntelligenceService(baseURL: Self.backend, clientKey: Self.clientKey),
                              device: device, voice: voice, body: BodySceneController())
        m.reset()
        var log: [String] = []
        func note(_ who: String, _ text: String) { log.append("\(who): \(text)") }
        func lofer() { note("LOFER", "\(voice.spoken.last ?? "")   [step: \(m.step.rawValue)]") }

        // 1. The story
        let story = InvestigationTests.tennis
        note("USER", story)
        await m.beginWithStory(story)
        lofer()
        XCTAssertEqual(m.step, .locate, "Pin down the spot first")
        XCTAssertEqual(m.A.bodyRegion, "r_sh_back")
        XCTAssertEqual(m.A.activityDuration, "two hours")

        // 2. Location
        note("USER", "(confirms the back of the right shoulder on the body)")
        m.confirmArea("r_sh_back"); await m.settle(); lofer()
        XCTAssertEqual(m.step, .movement)
        XCTAssertEqual(m.movementTest?.id, "arm_raise")

        // 3. Movement check
        note("USER", "It starts pulling about halfway.")
        await m.hear("It starts pulling about halfway."); await m.settle(); lofer()
        XCTAssertEqual(m.investigation.baseline?.outcome, .mildDiscomfort)
        XCTAssertEqual(m.question?.field, "observation:eases_when_stopped", "Observation: does it settle?")

        // 4. Observation
        note("USER", "Yes, it eased straight away.")
        await m.hear("Yes, it eased straight away."); await m.settle(); lofer()
        XCTAssertEqual(m.step, .confirm, "Enough information")
        XCTAssertEqual(m.investigation.readiness.informationSufficiency, .sufficient)

        // 5. Safety gate → TreatmentEngine → MockLoferDevice
        note("USER", "Yes, that's right.")
        await m.hear("Yes, that's right."); lofer()
        XCTAssertEqual(m.step, .suggest)
        XCTAssertEqual(m.tri?.level, .ok)
        note("PLAN", "\(m.validated?.plan.name ?? "") — \(m.validated?.plan.sequenceText ?? "") (validated by SafetyValidator)")
        note("USER", "Okay, let's start.")
        await m.hear("Okay, let's start."); lofer()
        XCTAssertTrue(device.isRunning)
        for _ in 0..<40 { m.reading = device.tick(seconds: 30) }
        note("DEVICE", "simulated session: \(Int(m.reading?.t ?? 0)) s, \(m.reading?.modality.label ?? "")")
        m.endRun(); lofer()

        // 6. Reassessment: the same movement, then how it feels
        XCTAssertEqual(m.step, .movement)
        note("USER", "It feels easier now.")
        await m.hear("It feels easier now."); lofer()
        note("USER", "It definitely feels looser now.")
        await m.hear("It definitely feels looser now."); lofer()
        XCTAssertEqual(m.step, .outcome)

        // 7. Body Memory
        let e = try XCTUnwrap(memory.all.first)
        let inv = try XCTUnwrap(e.investigation)
        note("MEMORY", "state: \(e.symptom.areaId), \(e.symptom.type ?? ""), after \(e.symptom.activity ?? ""), \(e.symptom.onset ?? "")")
        note("MEMORY", "investigation: " + inv.checks.map { "\($0.kind.rawValue)=\($0.response ?? $0.status.rawValue)" }.joined(separator: " · "))
        note("MEMORY", "patterns: " + inv.patterns.map { "\($0.label) (\($0.status.rawValue))" }.joined(separator: "; "))
        note("MEMORY", "observations: \(inv.baseline?.outcome.rawValue ?? "") → \(inv.repeatCheck?.outcome.rawValue ?? "") (\(inv.repeatCheck?.changeVsBaseline?.rawValue ?? ""))")
        note("MEMORY", "intervention: \(e.intervention?.planName ?? ""), \(e.intervention?.durationSec ?? 0) s; outcome: \(e.outcome.response ?? "") → \(e.outcome.pathway)")
        note("MEMORY", "Care Intelligence answered by: \(Set(inv.intelligenceSources).sorted().joined(separator: ", "))")

        XCTAssertTrue(inv.intelligenceSources.contains("mock"), "The backend's mock provider answered")
        XCTAssertFalse(inv.intelligenceSources.contains("local (fallback)"), "No turn fell back: \(m.intelligenceNote ?? "")")
        XCTAssertEqual(inv.repeatCheck?.changeVsBaseline, .better)
        XCTAssertFalse(inv.patterns.isEmpty)
        XCTAssertEqual(e.outcome.response, "little")
        let transcript = "===== LOFER END-TO-END SESSION =====\n" + log.joined(separator: "\n") + "\n"
        print(transcript)
        // Optionally save it (run with TEST_RUNNER_LOFER_E2E_LOG=/path/to/file.txt).
        if let path = ProcessInfo.processInfo.environment["LOFER_E2E_LOG"] { try? transcript.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// Any provider (mock or a real LLM): answer whatever Lofer asks, like a user would, and check
    /// the whole loop holds: no fallbacks, no diagnosis, safety and Body Memory intact.
    func testAdaptiveSessionWithAnyProvider() async throws {
        let provider = try await skipUnlessBackendIsUp()
        let voice = TranscriptVoice()
        let memory = BodyMemoryStore(defaults: UserDefaults(suiteName: "lofer.e2e.\(UUID().uuidString)")!)
        memory.clear()
        let device = MockLoferDevice()
        let m = CareFlowModel(memory: memory, intelligence: APICareIntelligenceService(baseURL: Self.backend, clientKey: Self.clientKey),
                              device: device, voice: voice, body: BodySceneController())
        m.reset()
        var log: [String] = []
        var clock = Date()
        func lofer() { log.append(String(format: "LOFER (%.1fs): %@   [%@]", Date().timeIntervalSince(clock), voice.spoken.last ?? "", m.step.rawValue)); clock = Date() }
        func user(_ t: String) { log.append("USER: \(t)"); clock = Date() }

        let story = InvestigationTests.tennis
        user(story); await m.beginWithStory(story); lofer()
        var turns = 0
        while ![.confirm, .suggest, .stop].contains(m.step) && turns < 10 {
            turns += 1
            switch m.step {
            case .locate where m.pendingSide != nil:
                user("(taps Right)"); m.chooseSide(.right)
            case .locate:
                let id = m.A.bodyRegion ?? "r_sh_back"
                user("(confirms \(BodyAtlas.shared[id].label) on the body)"); m.confirmArea(id)
            case .movement:
                user("It starts pulling about halfway."); await m.hear("It starts pulling about halfway.")
            case .clarify:
                let q = m.question
                if q?.field == "safety" { user("(taps None of these)"); m.answerSafety([]) }
                else if let o = q?.options.first(where: { $0.1 == "eased" }) ?? q?.options.first { user("(taps \(o.0))"); m.answerChip(q!.field, o.1) }
                else { user("It's mostly fine when I'm resting."); await m.hear("It's mostly fine when I'm resting.") }
            default:
                user("Yes."); await m.hear("Yes.")
            }
            await m.settle(); lofer()
        }
        XCTAssertLessThan(turns, 10, "Investigation should finish within its budget")
        if m.step == .confirm { user("Yes, that's right."); await m.hear("Yes, that's right."); lofer() }
        if m.step == .suggest {
            log.append("PLAN: \(m.validated?.plan.name ?? "") — \(m.validated?.plan.sequenceText ?? "") (SafetyValidator: \(m.tri?.level.rawValue ?? ""))")
            m.startTreatment()
            XCTAssertTrue(device.isRunning)
            m.reading = device.tick(seconds: 300); m.endRun(); lofer()
            if m.step == .movement { user("It feels easier now."); await m.hear("It feels easier now."); lofer() }
            if m.step == .reassess { user("It feels a little better."); m.reassess("little"); lofer() }
        }
        let e = try XCTUnwrap(memory.all.first, "The session is saved")
        let inv = try XCTUnwrap(e.investigation)
        log.append("MEMORY: checks: " + inv.checks.map { "\($0.kind.rawValue)=\($0.response ?? $0.status.rawValue)" }.joined(separator: " · "))
        log.append("MEMORY: patterns: " + inv.patterns.map { "\($0.label) (\($0.status.rawValue))" }.joined(separator: "; "))
        log.append("MEMORY: outcome: \(e.outcome.response ?? "–") → \(e.outcome.pathway); answered by: \(Set(inv.intelligenceSources).sorted().joined(separator: ", "))")

        XCTAssertTrue(inv.intelligenceSources.contains(provider), "The backend's \(provider) provider answered")
        XCTAssertFalse(inv.intelligenceSources.contains("local (fallback)"), "No turn fell back: \(m.intelligenceNote ?? "")")
        for line in voice.spoken { XCTAssertFalse(line.has("diagnos|\\btear\\b|tendin|impingement|root cause"), "No diagnosis: \(line)") }
        let transcript = "===== LOFER SESSION (provider: \(provider)) =====\n" + log.joined(separator: "\n") + "\n"
        print(transcript)
        if let path = ProcessInfo.processInfo.environment["LOFER_E2E_LOG"] { try? transcript.write(toFile: path + ".adaptive.txt", atomically: true, encoding: .utf8) }
    }

    /// Skips unless the backend answers; returns which provider it runs.
    @discardableResult
    private func skipUnlessBackendIsUp() async throws -> String {
        var req = URLRequest(url: Self.backend.appendingPathComponent("api/health"), timeoutInterval: 2)
        req.httpMethod = "GET"
        let data = try? await URLSession.shared.data(for: req)
        let provider = data.flatMap { (try? JSONSerialization.jsonObject(with: $0.0)) as? [String: Any] }?["provider"] as? String
        try XCTSkipUnless(provider != nil, "Lofer backend not running at \(Self.backend) (cd backend && npm start)")
        return provider!
    }
}

/// Records everything Lofer says (a VoiceAgent written only against the protocol).
@Observable
final class TranscriptVoice: VoiceAgent {
    private(set) var state: VoiceState = .idle
    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?
    private(set) var spoken: [String] = []
    func startListening() { state = .listening }
    func stopListening() { state = .idle }
    func submitText(_ text: String, replay: TextReplay) { onTranscript?(text, true) }
    func speak(_ text: String) { spoken.append(text) }
    func interrupt() { state = .idle }
    func transcriptHandled() { state = .idle }
}
