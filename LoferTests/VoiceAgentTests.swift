import XCTest
import Observation
@testable import Lofer

/// The app depends only on the VoiceAgent protocol, so any provider can be plugged in.
@MainActor
final class VoiceAgentTests: XCTestCase {

    // MARK: - Interchangeable providers

    func testCareFlowWorksWithAnyVoiceAgent() {
        let spy = SpyVoiceAgent()
        let memory = BodyMemoryStore(defaults: UserDefaults(suiteName: "lofer.tests.\(UUID().uuidString)")!)
        let model = CareFlowModel(memory: memory, intelligence: LocalCareIntelligenceService(), device: MockLoferDevice(),
                                  voice: spy, body: BodySceneController())
        model.beginWithBody()
        XCTAssertEqual(spy.spoken.last, "Show me where it's bothering you.", "Everything Lofer says goes through the protocol")
    }

    // MARK: - The mock's behaviour, through the protocol

    func testSubmittedTextArrivesAsAFinalTranscript() {
        let voice: any VoiceAgent = MockVoiceAgent()
        var received: [(String, Bool)] = []
        voice.onTranscript = { received.append(($0, $1)) }
        voice.submitText("  It feels tight.  ", replay: .instant)
        XCTAssertEqual(received.map(\.0), ["It feels tight."])
        XCTAssertEqual(received.map(\.1), [true])
        XCTAssertEqual(voice.state, .thinking)
        voice.transcriptHandled()
        XCTAssertEqual(voice.state, .idle)
    }

    func testReplayAsSpeechShowsWordsThenTheFinalText() async throws {
        let voice: any VoiceAgent = MockVoiceAgent()
        var partials: [String] = [], finals: [String] = []
        voice.onTranscript = { text, final in if final { finals.append(text) } else { partials.append(text) } }
        voice.submitText("Mostly overhead.", replay: .asSpeech)
        XCTAssertEqual(voice.state, .listening)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(partials, ["Mostly", "Mostly overhead."])
        XCTAssertEqual(finals, ["Mostly overhead."])
    }

    func testStoppingCancelsAReplayInProgress() async throws {
        let voice: any VoiceAgent = MockVoiceAgent()
        var finals: [String] = []
        voice.onTranscript = { text, final in if final { finals.append(text) } }
        voice.submitText("A longer sentence that takes a while.", replay: .asSpeech)
        voice.stopListening()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(finals.isEmpty)
    }
}

/// A third provider, written only against the protocol: if the app works with this,
/// it isn't relying on anything mock-specific.
@Observable
private final class SpyVoiceAgent: VoiceAgent {
    private(set) var state: VoiceState = .idle
    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?
    private(set) var spoken: [String] = []
    func startListening() { state = .listening }
    func stopListening() { state = .idle }
    func submitText(_ text: String, replay: TextReplay) { state = .thinking; onTranscript?(text, true) }
    func speak(_ text: String) { spoken.append(text) }
    func interrupt() { state = .idle }
    func transcriptHandled() { if state == .thinking { state = .idle } }
}
