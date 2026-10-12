import SwiftUI
import Observation
import simd

/// THE CARE FLOW (state machine). One episode, from "how are you feeling?" to Body Memory:
///
///   INVESTIGATE (repeats until there's enough information, within a budget):
///     user input → Care Intelligence (understands + PROPOSES a next step)
///                → InvestigationEngine (deterministic: safety first, validates, decides)
///                → one of: question · refine the spot on the body · movement check ·
///                  observation · "enough to consider care" · "not enough information" ·
///                  "better seen by a professional" · safety stop
///   then: confirm summary → safety gate → suggest [→ customise] → treat ⇄ paused →
///   same movement again → reassess → outcome → Body Memory (state → investigation →
///   observation → intervention → outcome). "stop" (safety) can happen from any step.
///
/// Rules this model keeps at every step:
///   • Warning signs are handled before anything else the user says (see `handleWarningSigns`).
///   • "Not sure" or a skipped safety answer is never treated as "no".
///   • Feeling worse during a session pauses it, and it only resumes after "has it settled?".
///   • Newer input, a reset or leaving the flow cancels any older work still in progress.
///   • Care Intelligence only proposes. The InvestigationEngine and SafetyValidator decide.
///
/// This model only orchestrates. Understanding = AssessmentService, safety = SafetyValidator,
/// plans = TreatmentEngine, hardware = DeviceInterface, memory = BodyMemoryStore.
/// Views read its state and call its actions; they never contain product logic.
@Observable @MainActor
final class CareFlowModel {
    enum Step: String { case listening, clarify, locate, confirm, correct, movement, suggest, custom, treat, paused, reassess, outcome, stop }
    struct Spot { var id: String; var p: SIMD3<Float>; var n: SIMD3<Float> }
    struct Care { var id: String; var point: Bool; var pair: String? = nil }
    struct PendingSide { var template: String; var noun: String; var both: Bool }

    // Dependencies (swappable: mock now, real later)
    @ObservationIgnored let memory: BodyMemoryStore
    @ObservationIgnored let intelligence: CareIntelligenceService
    @ObservationIgnored let device: DeviceInterface
    @ObservationIgnored let voice: any VoiceAgent
    @ObservationIgnored let body: BodySceneController
    @ObservationIgnored private let atlas = BodyAtlas.shared
    @ObservationIgnored var onExit: (() -> Void)?                 // back to home
    @ObservationIgnored var onOpenReport: ((String?) -> Void)?    // physio summary for an area group

    // What the user sees
    var agentLine = "Show me where it's bothering you."
    var heard = ""
    var step: Step = .locate
    var bodyReady = false
    var viewOffHome = false
    var limbView: String?

    // Body selection
    var focus = "body"
    var cand: String?
    var sel: Spot?
    var lit: [String] = []
    var pendingSide: PendingSide?
    var care: Care?

    // Understanding
    var A = AssessmentState()
    var question: AssessmentQuestion?
    @ObservationIgnored private var expect: String?
    @ObservationIgnored private var trail: [Step] = []
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var episodeId = ""            // one id per episode, so saving again updates it
    /// Bumped by every new input and every reset. Async work that started under an older
    /// value is stale (superseded or abandoned) and must not change anything.
    @ObservationIgnored private var generation = 0

    // Investigation: what's been learned this session beyond the assessment fields
    var investigation = InvestigationState()
    var conclusion: InvestigationAction?                      // set when it ends without care (not enough info / professional)
    var intelligenceNote: String?                             // why the last turn used the on-device fallback (debug only)
    @ObservationIgnored private var transcript: [ConversationTurn] = []
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var pendingInput: CareInput?   // the tap / spot / movement result being handled
    @ObservationIgnored private var freshResponse: CareIntelligenceResponse?   // Care Intelligence's answer to the input being handled now
    @ObservationIgnored private var pendingAck = ""            // what to acknowledge before the next prompt
    @ObservationIgnored private var locatePromptOverride: String?
    @ObservationIgnored private var planning: Task<Void, Never>?

    // Suggestion + safety
    var tri: TriageResult?
    var sym: SymptomSnapshot?
    var options: [TreatmentPlan] = []
    var plan: TreatmentPlan?
    var validated: SafetyValidator.Validation?
    @ObservationIgnored private var history: [Episode] = []

    // Movement check
    var movementTest: MovementTest?
    var movementPhase = "before"
    @ObservationIgnored private var skipMovement = false

    // Treatment
    static let previewSpeed = 20.0      // the preview runs sessions 20× faster than real time
    var reading: DeviceReading?
    var totalSeconds: Double = 1
    var checkIn = false
    var pausedForWorse = false
    @ObservationIgnored private var checkAt: [Double] = []
    @ObservationIgnored private var nextCheck = 0
    @ObservationIgnored private var checkStarted = Date()
    @ObservationIgnored private var feedbackLog: [Episode.Feedback] = []
    @ObservationIgnored private var adjustments: [String] = []
    @ObservationIgnored private var runResult: (elapsed: Int, log: [Episode.LogEntry])?
    @ObservationIgnored private var flagsAtStart = 0           // warning signs known when the session started
    @ObservationIgnored private var stopReason: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    // Result
    var result: TreatmentEngine.Reassessment?
    var why = ""
    var routineSaved = false
    @ObservationIgnored private var response: String?

    init(memory: BodyMemoryStore, intelligence: CareIntelligenceService, device: DeviceInterface, voice: any VoiceAgent, body: BodySceneController) {
        self.memory = memory; self.intelligence = intelligence; self.device = device; self.voice = voice; self.body = body
        body.onReady = { [weak self] in Task { @MainActor in self?.bodyReady = true; self?.refresh() } }
        body.onTap = { [weak self] p, n in Task { @MainActor in self?.tapped(p, n) } }
        body.onViewChanged = { [weak self] off in Task { @MainActor in self?.viewOffHome = off } }
        bodyReady = body.isReady
    }

    // MARK: - Starting an episode
    func reset() {
        generation += 1; episodeId = "e-\(UUID().uuidString)"
        stopTicker(); _ = device.stop(); body.setPatches(around: []); body.setSpot(nil, normal: nil); body.setLimbView(nil, limb: nil)
        focus = "body"; cand = nil; sel = nil; lit = []; pendingSide = nil; care = nil
        A = AssessmentState(); question = nil; expect = nil; trail = []; startedAt = Date()
        tri = nil; sym = nil; options = []; plan = nil; validated = nil; history = []
        movementTest = nil; movementPhase = "before"; skipMovement = false
        reading = nil; checkIn = false; pausedForWorse = false; feedbackLog = []; adjustments = []; runResult = nil
        flagsAtStart = 0; stopReason = nil; response = nil
        investigation = InvestigationState(); conclusion = nil; intelligenceNote = nil; transcript = []; turn = 0
        pendingInput = nil; freshResponse = nil; pendingAck = ""; locatePromptOverride = nil; planning?.cancel(); planning = nil
        result = nil; why = ""; routineSaved = false; limbView = nil; heard = ""
    }
    /// Touch route: the body comes first, the story after.
    func beginWithBody() { reset(); step = .locate; say("Show me where it's bothering you."); body.frame("body", role: .select, turn: true); refresh() }
    /// Voice/text route: the story was told on the home screen.
    func beginWithStory(_ text: String) async {
        reset()
        heard = "“\(text)”"
        let g = generation
        transcript.append(.init(role: .user, text: text))
        let response = await consult(CareInput(kind: .utterance, text: text), expect: "story")
        guard g == generation else { return }      // the user left or started again meanwhile
        let r = ParsedUtterance.merged(local: SymptomParser.parse(text), with: response)
        var learned = AssessmentService.update(&A, with: r, expect: "story")
        recordReport(text, learned: learned)
        freshResponse = response
        let res = r.entry.flatMap { resolve(r, $0) }
        if case .id(let id)? = res { AssessmentService.setRegion(&A, id); learned.append("region") }
        step = .listening
        body.frame("body", role: .select, turn: true)
        if A.safetyFlags.contains(where: { $0.level == .urgent }) { return runTriage() }
        if let res { await applyTarget(res, advanceAfter: false) }
        advance(learned)
    }

    // MARK: - Hearing the user (voice or typed) — read against the current step
    func hear(_ text: String) async {
        heard = "“\(text)”"
        generation += 1; let g = generation
        transcript.append(.init(role: .user, text: text))
        // While investigating, Care Intelligence reads the words in the context of the whole
        // session. Warning signs and UI commands ("start", "too strong") are ALWAYS also read
        // on-device, so safety never depends on the network.
        let investigating: [Step] = [.listening, .clarify, .locate, .confirm, .correct, .movement]
        let response = investigating.contains(step) ? await consult(CareInput(kind: .utterance, text: text), expect: expect) : nil
        if response == nil { await Task.yield() }
        guard g == generation else { return }      // superseded by newer input, a reset or leaving
        let r = ParsedUtterance.merged(local: SymptomParser.parse(text), with: response)
        freshResponse = response
        defer { freshResponse = nil }
        let t = text.lowercased()
        if handleWarningSigns(r) { return }        // warning signs come before any other intent
        switch step {
        case .clarify, .listening, .correct: return await understand(r)
        case .confirm:
            if r.isDescriptive { return await understand(r) }
            if r.deny { return correction() }
            if r.confirm { return confirmYes() }
            return say("Is that right? You can say yes, or tell me what to change.")
        case .movement:
            if r.skip { return skipMovementCheck() }
            if let m = r.movement { return movementAnswer(m) }
            return say("How did that feel? Fine, a little uncomfortable, quite uncomfortable, or not comfortable at all?")
        case .suggest, .custom:
            if let p = r.prefs { return applyPrefs(p) }
            if r.start || r.confirm { return startTreatment() }
            if let d = r.direction, sel != nil { var p = TreatmentPrefs(); p.focus = d; return applyPrefs(p) }
            return say("You can say things like “more heat”, “keep it gentle” or “no electrical stimulation”. Say “start” when you're ready.")
        case .treat, .paused:
            if t.has("\\b(stop|end|finish)\\b") { return endRun() }
            if pausedForWorse {
                // Paused because it got worse: only the answer to "has it settled?" moves things on.
                if r.feedback == "worse" || r.response == "worse" || r.deny || t.has("still|not settled|hasn'?t settled|no better") { return stillWorse() }
                if r.confirm || ["much", "little"].contains(r.response) || t.has("settled|eased|gone|back to normal") { return settled() }
                return say(Self.settleQuestion)
            }
            if t.has("pause|hold on|wait"), step == .treat { device.pause(); step = .paused; return say("Paused.") }
            if t.has("resume|continue|carry on|go on"), step == .paused { return resumeRun(gentler: false) }
            if let f = r.prefs?.focus ?? (t.has("focus|move") ? r.direction : nil) { return moveFocus(f) }
            if let fb = r.feedback { return feedback(fb, via: "voice") }
            if let i = r.prefs?.intensity { return feedback(i < 0 ? "too strong" : "too weak", via: "voice") }
            return say("You can say “too strong”, “that feels good”, “move the focus lower”, or “stop”.")
        case .reassess:
            if let resp = r.response { return reassess(resp) }
            return say("Is it much better, a little better, about the same, or worse?")
        case .outcome, .stop:
            return say("Tap Done when you're finished.")
        case .locate:
            if r.isDescriptive && r.entry == nil {
                let learned = AssessmentService.update(&A, with: r, expect: nil)
                if r.flags.contains(where: { $0.level != .caution }) { return advance(learned) }
            }
            if r.zoom, let c = cand, !atlas.isLeaf(c) { return zoomIn(c) }
            if let e = r.entry, let res = resolve(r, e) { return await applyTarget(res) }
            if let ps = pendingSide, let s = r.side { return await applyTarget(.id(ps.template.replacingOccurrences(of: "{s}", with: s.rawValue))) }
            if let ps = pendingSide, r.bilateral || t.has("\\bboth\\b") { return confirmBoth(ps.template) }
            if r.confirm, sel != nil { return confirmSpot() }
            if r.confirm, cand != nil { return say("Should I zoom in, or take the whole area?") }
            if let w = r.turn { body.turn(to: w); return say("Turning you around.") }
            if let d = r.direction, sel != nil || cand != nil || !lit.isEmpty { return refine(d, slight: r.slight) }
            if r.direction != nil { return say("Tap roughly where it is first, then I can move it.") }
            if A.userDescription.isEmpty && (r.type != nil || r.activity != nil || r.onset != nil) { return await understand(r) }
            return say("You can tap the body, or say something like “slightly lower” or “my left calf”.")
        }
    }

    /// WARNING SIGNS FIRST. Once Lofer has moved past the questions (movement check onwards),
    /// anything the user says is checked for warning signs before any other intent, and the
    /// original sign and its urgency are kept as reported. Returns true if it decided what happens next.
    /// (Before that point, `understand` records signs and `advance` runs the safety gate.)
    private func handleWarningSigns(_ r: ParsedUtterance) -> Bool {
        let active: [Step] = [.movement, .suggest, .custom, .treat, .paused, .reassess, .outcome, .stop]
        guard active.contains(step), !r.flags.isEmpty || !r.uncertainFlags.isEmpty else { return false }
        A.userDescription.append(r.raw.trimmingCharacters(in: .whitespaces))     // keep the user's own words as evidence
        for f in r.flags where !A.safetyFlags.contains(where: { $0.label == f.label }) { A.safetyFlags.append(f) }
        for f in r.uncertainFlags where !A.uncertainSigns.contains(where: { $0.label == f.label }) { A.uncertainSigns.append(f) }
        let serious = r.flags.contains { $0.level != .caution }
        if serious { safetyStop(); return true }
        let label = (r.flags.first ?? r.uncertainFlags.first)!.label.lowercased()
        switch step {
        case .treat, .paused:
            // A caution-level or uncertain sign during care: pause, then check before going on.
            pauseForWorsening(note: "Paused: \(label) mentioned during the session")
            say("You mentioned \(label). I've paused. \(Self.settleQuestion)")
            return true
        case .movement, .suggest, .custom:
            if !r.uncertainFlags.isEmpty && r.flags.isEmpty {
                // Unsure about a warning sign: ask the safety check (again) before going on.
                A.answers["safety"] = nil; advance(skipAck: true); return true
            }
            if step == .movement {
                if r.movement != nil { return false }       // the movement answer is still read, with the sign on record
                say("Noted: \(label). How did the movement feel overall?"); return true
            }
            let t = triageNow()
            if t.level == .stop { go(.stop); saveEpisode(); say(stopLine(t)); return true }
            if let p = plan { pick(p) }                     // re-check the plan against the new limits
            say("Noted: \(label). I've kept the session within the limits for that.")
            return true
        case .reassess:
            return false                                     // the answer is still read; the new sign counts against it
        default:
            saveEpisode()                                    // add it to today's record
            say("I've added that to today's record.")
            return true
        }
    }
    /// A serious warning sign: stop any running session FIRST, then explain.
    private func safetyStop() {
        if step == .treat || step == .paused {
            stopTicker(); runResult = device.stop(); body.setPatches(around: []); checkIn = false; pausedForWorse = false
            stopReason = "Stopped: warning sign reported during the session"
        } else if runResult != nil, stopReason == nil {
            stopReason = "Warning sign reported after the session"
        }
        let t = triageNow()
        go(.stop); saveEpisode()
        say(t.urgent ? stopLine(t) : "Let's stop here. \(stopLine(t))")
    }

    /// Everything said while Lofer is getting to know the problem.
    private func understand(_ r: ParsedUtterance) async {
        let t = r.raw.lowercased()
        // While answering a question, a body word only moves the area if it sounds like a correction.
        let relocate = r.entry != nil && (A.bodyRegion == nil || expect == nil || expect == "story" || t.has("actually|it'?s (my|in|on|more)|not (my|the)|rather|instead"))
        // An answer to an observation request ("did it ease when you stopped?").
        if let e = expect, e.hasPrefix("observation:"), let q = question, let value = observationValue(r, q) {
            return answerObservation(e, value)
        }
        var learned = AssessmentService.update(&A, with: r, expect: expect)
        // A question Care Intelligence phrased itself (a field the app has no special handling for):
        // the reply answers it, and is kept as evidence.
        if let e = expect, !["story", "safety", "sensation", "triggers", "onset", "severity", "previous"].contains(e),
           !e.hasPrefix("observation:"), A.answers[e] == nil, !r.raw.trimmingCharacters(in: .whitespaces).isEmpty {
            A.answers[e] = r.unsure ? .uncertain : r.skip ? .skipped : .affirmative
            learned.append("answered:\(e)")
            investigation.addEvidence(.userReport, "\(question?.text ?? e) → “\(r.raw)”", field: e, value: r.raw)
        }
        recordReport(r.raw, learned: learned)
        // Only a reply that addresses the question counts as answering it.
        if let e = expect, learned.contains("answered:\(e)") {
            A.questionsAsked += 1
            investigation.addCheck(.question, purpose: e, prompt: question?.text ?? e, response: r.raw, status: Self.checkStatus(A.answers[e]))
        }
        if relocate, let e = r.entry, let res = resolve(r, e) {
            if case .id(let id) = res, id != A.bodyRegion { learned.append("region") }
            await applyTarget(res, advanceAfter: false)
        } else if learned.isEmpty, let d = r.direction, sel != nil || !lit.isEmpty {
            refine(d, slight: r.slight, keepFlow: true); care = nil; A.regionConfirmed = false
            return say("Got it, \(sel.map { atlas[$0.id].spoken } ?? "there"). \(question?.text ?? "")")
        }
        if learned.isEmpty && step == .clarify { return say("Sorry, I didn't quite catch that. \(question?.text ?? "")") }
        advance(learned)
    }

    /// Decide the next step from what's known and what's missing. One question at a time.
    /// Decide what happens next. Safety first (deterministic, immediate). Otherwise Care
    /// Intelligence's proposal for this input goes through the InvestigationEngine. For a tap
    /// or other structured input, Care Intelligence is consulted first (asynchronously).
    func advance(_ learned: [String] = [], skipAck: Bool = false) {
        if A.safetyFlags.contains(where: { $0.level != .caution }) || A.safetyUnresolved { return runTriage() }
        let ack = skipAck ? "" : pendingAck.isEmpty ? AssessmentService.ack(A, learned: learned) : pendingAck
        let appAck = !pendingAck.isEmpty
        pendingAck = ""
        if let ps = pendingSide { go(.locate); expect = nil; return say(ack, ps.both ? "Is it both \(ps.noun)s, or one more than the other?" : "Which \(ps.noun) is it, left or right?") }
        if let r = freshResponse { freshResponse = nil; return present(r, ack: ack, preferAppAck: appAck || skipAck) }
        let input = pendingInput ?? CareInput(kind: .answer)
        pendingInput = nil
        let g = generation
        planning = Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await self.consult(input, expect: self.expect)
            guard g == self.generation, !Task.isCancelled else { return }   // superseded or left
            self.present(r, ack: ack, preferAppAck: appAck || skipAck)
        }
    }
    /// Waits for a pending "what next?" decision (tests and the demo use this).
    func settle() async { await planning?.value }

    // MARK: - Investigation: consult, decide, show
    /// Asks Care Intelligence about this input, with the session's context. Never throws: if
    /// the configured service fails (backend down, timeout, malformed answer), the on-device
    /// service answers instead, so the care flow never breaks.
    private func consult(_ input: CareInput, expect: String?) async -> CareIntelligenceResponse {
        turn += 1
        let request = CareRequest(
            requestId: UUID().uuidString, sessionId: episodeId, turn: turn, latestUserInput: input, expectedField: expect,
            conversationHistory: Array(transcript.suffix(10)), currentAssessmentState: A, selectedBodyRegion: selectedRegion,
            investigation: investigation, completedMovementChecks: investigation.movementObservations,
            relevantBodyMemory: memory.relevantMemory(for: A.bodyRegion, activity: A.activityContext),
            currentCareFlowState: step.rawValue)
        do {
            let r = try await intelligence.respond(to: request)
            guard r.requestId == request.requestId else { throw CareIntelligenceError.mismatchedRequest }
            investigation.intelligenceSources.append(r.provider); intelligenceNote = nil
            return r
        } catch {
            intelligenceNote = "On-device fallback: \(error)"
            investigation.intelligenceSources.append("local (fallback)")
            return LocalCareIntelligenceService.response(to: request)
        }
    }
    private var selectedRegion: SelectedRegion? {
        guard let id = sel?.id ?? care?.id ?? A.bodyRegion, atlas.node(id) != nil else { return nil }
        return SelectedRegion(id: id, label: atlas[id].label, group: atlas.group(of: id), laterality: A.laterality,
                              confirmed: A.regionConfirmed, isLeaf: atlas.isLeaf(id))
    }
    private var investigationContext: InvestigationEngine.Context {
        InvestigationEngine.Context(A: A, investigation: investigation, triage: triagePreview(),
                                    movement: movementTest ?? A.bodyRegion.flatMap { MovementTest.forArea($0) },
                                    historyCount: A.bodyRegion.map { memory.history(for: $0).count } ?? 0)
    }
    /// The safety gate's view right now (without changing the visible state).
    private func triagePreview() -> TriageResult? {
        guard !A.safetyFlags.isEmpty || A.safetyUnresolved || A.bodyRegion != nil else { return nil }
        var s = AssessmentService.symptom(A)
        if let r = A.bodyRegion { s.automaticCarePaused = memory.automaticCarePause(for: r) != nil }
        return SafetyValidator.triage(s, profile: memory.profile)
    }

    /// Takes in Care Intelligence's view, lets the engine decide, and shows the result.
    private func present(_ response: CareIntelligenceResponse, ack: String, preferAppAck: Bool) {
        investigation.cycles += 1
        if !response.possibleContributingPatterns.isEmpty { investigation.patterns = response.possibleContributingPatterns }
        for e in response.evidenceUpdates {
            investigation.addEvidence(.careIntelligence, e.summary, field: e.field, value: e.value, supports: e.supports, weakens: e.weakens)
        }
        let ctx = investigationContext
        investigation.uncertainties = response.uncertainties.isEmpty ? InvestigationEngine.uncertainties(ctx) : response.uncertainties
        let (action, overridden) = InvestigationEngine.decide(proposal: response.recommendedNextAction, ctx)
        investigation.nextAction = action
        investigation.readiness = InvestigationEngine.readiness(ctx)
        if let overridden { intelligenceNote = overridden }
        // Wording: Care Intelligence's, only if it passes the language guard and matches what we're doing.
        let theirAck = response.userFacingResponse.acknowledgement
        let lead = !preferAppAck && response.provider != "local" && CareLanguage.isAcceptable(theirAck) ? theirAck : ack
        let theirPrompt = response.userFacingResponse.prompt
        let prompt = action == response.recommendedNextAction && CareLanguage.isAcceptable(theirPrompt) ? theirPrompt : nil
        perform(action, lead: lead, prompt: prompt)
    }

    /// Shows an investigation action with the existing screens: conversation drives the UI.
    private func perform(_ action: InvestigationAction, lead: String, prompt: String?) {
        switch action {
        case .askQuestion(let q):
            // Known fields use the app's own answer chips (so taps map to structured answers).
            let base = ["sensation", "safety", "triggers", "onset", "severity", "previous"].contains(q.field)
                ? AssessmentService.question(q.field, A)
                : AssessmentQuestion(field: q.field, text: q.question, options: (q.options ?? []).map { ($0.label, $0.value) }, multi: q.multiSelect ?? false)
            question = AssessmentQuestion(field: base.field, text: prompt ?? q.question, hint: base.hint, options: base.options, multi: base.multi)
            expect = q.field; go(.clarify); say(lead, question!.text)
        case .refineBodyLocation(let l):
            expect = nil; locatePromptOverride = prompt ?? l.prompt
            if l.requestedRefinement != .region, sel == nil, cand == nil, lit.isEmpty, let r = A.bodyRegion {
                Task { await applyTarget(.id(r), advanceAfter: false) }      // show the area so it can be refined
            }
            go(.locate); say(lead, locatePromptOverride!)
        case .movementCheck(let m):
            movementTest = MovementTest.all.first { $0.id == m.movementId } ?? movementTest
            movementStep("before", lead: lead, prompt: prompt)
        case .requestUserObservation(let o):
            // The observation question already acknowledges what was felt ("You felt it about halfway…").
            question = AssessmentQuestion(field: "observation:\(o.observationId)", text: prompt ?? o.prompt, options: o.options.map { ($0.label, $0.value) })
            expect = question!.field; go(.clarify); say(question!.text)
        case .proceedToCare:
            expect = nil; go(.confirm); say(lead, confirmLine)
        case .insufficientInformation(let c), .recommendProfessionalAssessment(let c):
            endWithoutCare(action, reason: c.reason, message: c.message)
        case .safetyStop(let s):
            // The deterministic gate decides. If it doesn't see a stop, Care Intelligence's concern
            // still prevents care: Lofer recommends a professional instead of treating.
            if triagePreview()?.level == .stop { return runTriage() }
            endWithoutCare(.recommendProfessionalAssessment(.init(reason: s.reason, message: "I'd rather not start a session for this. It's worth having it looked at by a GP or physiotherapist.")),
                           reason: s.reason, message: "I'd rather not start a session for this. It's worth having it looked at by a GP or physiotherapist.")
        }
    }
    private func endWithoutCare(_ action: InvestigationAction, reason: String, message: String) {
        conclusion = action; investigation.conclusion = reason; expect = nil
        go(.stop); saveEpisode(); say(message)
    }

    // MARK: - Evidence: the user is a sensor
    private func recordReport(_ text: String, learned: [String]) {
        let facts = learned.filter { !$0.hasPrefix("answered:") }
        guard !facts.isEmpty, !text.isEmpty else { return }
        investigation.addEvidence(.userReport, "“\(text)”", field: facts.joined(separator: ","))
    }
    private static func checkStatus(_ s: AnswerStatus?) -> Check.Status {
        switch s { case .uncertain?: .uncertain; case .skipped?: .skipped; default: .answered }
    }
    private func observationValue(_ r: ParsedUtterance, _ q: AssessmentQuestion) -> String? {
        if r.unsure { return "unsure" }
        let t = r.raw.lowercased()
        if let o = q.options.first(where: { t.has(NSRegularExpression.escapedPattern(for: $0.0.lowercased())) }) { return o.1 }
        if r.confirm, let first = q.options.first { return first.1 }
        if r.deny, q.options.count > 1 { return q.options[1].1 }
        return nil
    }
    /// An answer to an observation request, as evidence.
    func answerObservation(_ field: String, _ value: String) {
        let id = String(field.dropFirst("observation:".count))
        let label = question?.options.first { $0.1 == value }?.0 ?? value
        investigation.addCheck(.observation, purpose: id, prompt: question?.text ?? id, response: label, status: value == "unsure" ? .uncertain : .answered)
        investigation.addEvidence(.userObservation, "\(question?.text ?? id) → \(label)", field: id, value: value)
        A.answers[field] = value == "unsure" ? .uncertain : .affirmative
        pendingInput = CareInput(kind: .observation, text: label, field: id, value: value)
        pendingAck = value == "unsure" ? "That's fine." : "Thanks, that helps."
        advance()
    }

    var confirmLine: String {
        let checked = investigation.baseline.map { " The \($0.name.lowercased()) felt \(MovementResult(feel: Self.feel($0.outcome)).phrase)\($0.whereInMovement.map { ", \($0)" } ?? "")." } ?? ""
        return "\(AssessmentService.summary(A))\(checked) Is that right?"
    }
    static func feel(_ o: MovementObservation.Outcome) -> MovementResult.Feel {
        [.comfortable: .fine, .mildDiscomfort: .little, .significantDiscomfort: .quite, .unableToPerformComfortably: .cannot][o]!
    }
    private var locatePrompt: String {
        if let o = locatePromptOverride { return o }
        if sel != nil { return "Here? Tap “That’s the spot”, or tell me which way to move it." }
        if !lit.isEmpty { return "Show me exactly where. Tap it, or say something like ‘more towards the back’." }
        return "Show me where it's bothering you."
    }
    private func go(_ s: Step) { if step != s { trail.append(step); step = s }; refresh() }

    // MARK: - Answers from chips
    func answerChip(_ field: String, _ value: String) {
        if field == "sensation" && value == "__other" { expect = "sensation"; return say("Tell me in your own words. Whatever comes to mind.") }
        if field.hasPrefix("observation:") { return answerObservation(field, value) }
        AssessmentService.answer(&A, field: field, value: value); A.questionsAsked += 1
        let label = question?.options.first { $0.1 == value }?.0 ?? value
        investigation.addCheck(.question, purpose: field, prompt: question?.text ?? field, response: label, status: .answered)
        investigation.addEvidence(.userReport, "\(question?.text ?? field) → \(label)", field: field, value: value)
        pendingInput = CareInput(kind: .answer, text: label, field: field, value: value)
        let learned = ["sensation": ["sensation"], "triggers": value == "__rest" ? ["symptomsAtRest"] : value == "__none" ? [] : ["movementTriggers"], "onset": ["onset"]][field] ?? []
        advance(learned)
    }
    func answerSafety(_ labels: [String]) {
        AssessmentService.addSafetyAnswers(&A, labels); A.questionsAsked += 1
        let answer = labels.isEmpty ? "None of these" : labels.joined(separator: ", ")
        investigation.addCheck(.question, purpose: "safety", prompt: "Numbness, tingling, swelling or weakness?", response: answer, status: .answered)
        pendingInput = CareInput(kind: .answer, text: answer, field: "safety", value: labels.isEmpty ? "none" : "reported")
        advance()
    }
    /// "Not sure" / "Skip" on the safety question: recorded as such, never as "no".
    func answerSafetyUnsure() {
        AssessmentService.setSafety(&A, .uncertain); A.questionsAsked += 1
        investigation.addCheck(.question, purpose: "safety", prompt: "Numbness, tingling, swelling or weakness?", response: "Not sure", status: .uncertain)
        advance()
    }
    func skipSafety() {
        AssessmentService.setSafety(&A, .skipped); A.questionsAsked += 1
        investigation.addCheck(.question, purpose: "safety", prompt: "Numbness, tingling, swelling or weakness?", response: nil, status: .skipped)
        advance()
    }
    /// From the "not enough information" screen: go back and answer the safety check.
    func revisitSafety() { A.answers["safety"] = nil; A.uncertainSigns = []; tri = nil; advance(skipAck: true) }
    func confirmYes() { runTriage() }
    func correction() { go(.correct); say("No problem. What should I change? Tap one, or just tell me.") }
    func correct(_ what: String) {
        switch what {
        case "place": A.regionConfirmed = false; care = nil; go(.locate); return say(locatePrompt)
        case "feel": A.sensation = nil; A.sensationWords = nil; A.answers["sensation"] = nil
        case "when": A.onset = nil; A.activityContext = nil; A.answers["onset"] = nil
        default: A.movementTriggers = []; A.symptomsAtRest = nil; A.answers["triggers"] = nil
        }
        A.questionsAsked = min(A.questionsAsked, AssessmentService.maxFollowUps - 1)
        advance(skipAck: true)
    }
    func backToSummary() { go(.confirm); say(confirmLine) }

    // MARK: - Safety gate
    /// Runs the deterministic safety gate on everything known right now, including any
    /// pause on automatic care stated after an earlier session.
    @discardableResult private func triageNow() -> TriageResult {
        var s = AssessmentService.symptom(A)
        if let r = A.bodyRegion { s.automaticCarePaused = memory.automaticCarePause(for: r) != nil }
        sym = s
        let t = SafetyValidator.triage(s, profile: memory.profile); tri = t
        return t
    }
    private func stopLine(_ t: TriageResult) -> String {
        t.urgent ? "This needs medical attention rather than Lofer." : t.deferred ? "I don't have enough information to recommend a session here."
            : "I don't think Lofer should treat this one. Let me explain why."
    }
    private func runTriage() {
        let t = triageNow()
        if t.level == .stop { go(.stop); saveEpisode(); return say(stopLine(t)) }
        if A.movementBefore == nil && !skipMovement { return movementStep("before") }
        suggestStep()
    }

    // MARK: - Movement check (before and after)
    func movementStep(_ phase: String, lead: String = "", prompt: String? = nil) {
        if movementTest == nil, let r = A.bodyRegion { movementTest = MovementTest.forArea(r) }
        guard let test = movementTest else { skipMovement = true; return phase == "before" ? suggestStep() : reassessStep() }
        movementPhase = phase; go(.movement)
        say(lead, phase == "before" ? (prompt ?? test.intro) : "Let's try that same movement again, and see how it feels now.")
    }
    /// A movement result, as structured evidence.
    private func recordMovement(_ m: MovementResult, phase: MovementObservation.Phase, words: String? = nil) {
        guard let test = movementTest else { return }
        var o = MovementObservation(movementId: test.id, name: test.name, phase: phase, outcome: MovementObservation.outcome(m.feel),
                                    whereInMovement: m.whereInMovement, location: m.sideOfIt, quality: m.quality, userDescription: words)
        if phase == .repeatCheck, let b = investigation.baseline {
            let order: [MovementObservation.Outcome] = [.comfortable, .mildDiscomfort, .significantDiscomfort, .unableToPerformComfortably]
            let d = order.firstIndex(of: o.outcome)! - order.firstIndex(of: b.outcome)!
            o.changeVsBaseline = d < 0 ? .better : d > 0 ? .worse : .same
        }
        investigation.movementObservations.append(o)
        investigation.addCheck(.movement, purpose: phase == .baseline ? "See how the area responds to movement" : "Compare with before care",
                               prompt: test.name, response: m.phrase + (m.whereInMovement.map { ", \($0)" } ?? ""), status: .answered)
        investigation.addEvidence(.movementCheck, "\(test.name) (\(phase == .baseline ? "before" : "after")): \(m.phrase)\(m.whereInMovement.map { ", \($0)" } ?? "")",
                                  field: test.id, value: o.outcome.rawValue)
    }
    func movementAnswer(_ m: MovementResult) {
        if movementPhase == "after" { A.movementAfter = m; recordMovement(m, phase: .repeatCheck); return reassessStep() }
        A.movementBefore = m
        recordMovement(m, phase: .baseline)
        // The safety layer decides what a difficult movement means (gentler care, or stop).
        let t = triageNow()
        if t.level == .stop { go(.stop); saveEpisode(); return say(t.deferred ? stopLine(t) : "Thanks for trying. I don't think Lofer should treat this today.") }
        let detail = [m.whereInMovement, m.quality.map { "a \($0) feeling" }, m.sideOfIt.map { "on the \($0)" }].compactMap { $0 }.joined(separator: ", ")
        // The result is evidence: the investigation decides what's next (another check, or enough).
        pendingAck = [.fine: "Good, that helps.", .little: "Thanks. I've noted that\(detail.isEmpty ? "" : " (\(detail))").", .quite: "Thanks. I'll keep things gentle.", .cannot: "That's fine, no need to push it."][m.feel]!
        pendingInput = CareInput(kind: .movementResult, text: m.phrase, field: movementTest?.id, value: MovementObservation.outcome(m.feel).rawValue)
        advance()
    }
    func skipMovementCheck() {
        skipMovement = true
        if movementPhase == "after" { return reassessStep() }
        investigation.addCheck(.movement, purpose: "See how the area responds to movement", prompt: movementTest?.name ?? "Movement check", response: nil, status: .skipped)
        pendingInput = CareInput(kind: .movementResult, text: "Skipped", field: movementTest?.id, value: "skipped")
        pendingAck = "No problem."
        advance()
    }

    // MARK: - Suggest
    private func suggestStep(ack: String = "") {
        guard let s = sym ?? Optional(AssessmentService.symptom(A)), let t = tri, let region = A.bodyRegion else { return }
        history = memory.history(for: region)
        let sug = TreatmentEngine.suggest(s, t, profile: memory.profile, history: history, routine: memory.routine(for: region, activity: s.activity),
                                          investigation: investigation)
        options = sug.options
        pick(sug.pick)
        go(.suggest)
        say(ack, "\(sug.headline) Would you like to try this, or is there something you'd change?")
    }
    func pick(_ p: TreatmentPlan) { plan = p; if let t = tri { validated = SafetyValidator.validate(p, t) }; refresh() }
    func applyPrefs(_ prefs: TreatmentPrefs) {
        guard let p = plan else { return }
        let (np, said) = TreatmentEngine.apply(prefs, to: p, profile: memory.profile)
        if let f = prefs.focus, sel != nil { refine(f, slight: true, keepFlow: true) }
        pick(np)
        let notes = validated?.notes.isEmpty == false ? " " + validated!.notes.joined(separator: " ") : ""
        say(said.isEmpty ? "Okay.\(notes)" : "Done: \(said.joined(separator: ", ")).\(notes)")
    }
    func openCustomise() { go(.custom); say("Change anything you like. I’ll keep it within safe limits.") }
    func closeCustomise() { go(.suggest) }
    func toggle(_ m: Modality) {
        guard var p = plan else { return }
        if p.steps.contains(where: { $0.modality == m }) { p.steps.removeAll { $0.modality == m } }
        else { let heatIdx = p.steps.firstIndex { $0.modality == .heat } ?? p.steps.endIndex; p.steps.insert(.init(modality: m, intensity: 2, minutes: 3), at: m == .heat ? p.steps.endIndex : heatIdx) }
        p.adjusted = true; if p.kind != .routine { p.kind = .custom }; pick(p)
    }
    func adjust(_ m: Modality, minutes: Int? = nil, intensity: Int? = nil) {
        guard var p = plan, let i = p.steps.firstIndex(where: { $0.modality == m }) else { return }
        if let v = minutes { p.steps[i].minutes = max(1, min(10, v)) }
        if let v = intensity { p.steps[i].intensity = max(1, min(5, v)) }
        p.adjusted = true; if p.kind != .routine { p.kind = .custom }; pick(p)
    }

    // MARK: - Treat
    func startTreatment() {
        guard let p = plan, [.suggest, .custom].contains(step) else { return }
        let t = triageNow()                       // decide on everything known now, not an older result
        let v = SafetyValidator.validate(p, t); validated = v
        guard v.ok, let cmd = v.command else { go(.stop); saveEpisode(); return say(stopLine(t)) }
        flagsAtStart = A.safetyFlags.count
        device.start(cmd)                         // the only way anything reaches the device
        totalSeconds = Double(v.plan.minutes * 60)
        checkAt = TreatmentEngine.checkIns(history); nextCheck = 0; checkIn = false
        go(.treat)
        placePatches()
        say("Starting gently. Just tell me any time if it's too much.")
        startTicker()
    }
    /// The session runs on its own clock (not tied to drawing), so it keeps going if the screen redraws slowly.
    private func startTicker() {
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tickSession(0.25)
            }
        }
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil }
    private func tickSession(_ dt: Double) {
        guard step == .treat || step == .paused, let rd = device.tick(seconds: dt * Self.previewSpeed) else { return }
        reading = rd
        body.setPatchActivity(rd.modality, paused: rd.paused)
        let frac = rd.t / max(1, totalSeconds)
        if step == .treat && !checkIn && nextCheck < checkAt.count && frac >= checkAt[nextCheck] {
            checkIn = true; checkStarted = Date(); nextCheck += 1; say("How does this feel?")
        }
        if checkIn && Date().timeIntervalSince(checkStarted) > 14 { checkIn = false }      // no answer → carry on quietly
        if rd.done { endRun() }
    }
    func feedback(_ value: String, via: String = "tap") {
        guard let rd = reading, let t = tri else { return }
        feedbackLog.append(.init(t: Int(rd.t), value: value, via: via)); checkIn = false
        switch TreatmentEngine.feedbackAction(value) {
        case .level(let delta, let line)?:
            let change = SafetyValidator.validateLevel(rd.level + delta, modality: rd.modality, t)
            if delta < 0 && change.intensity >= rd.level {
                // "Too strong" at the gentlest level: comfort, not worsening. Pause and let them choose.
                device.pause(); step = .paused; adjustments.append("Paused: too strong at the gentlest level")
                return say("That's already the gentlest level, so I've paused. Resume when you're ready, or stop here.")
            }
            device.setIntensity(change)
            adjustments.append("Intensity \(rd.level) → \(change.intensity) (\(value))")
            say(change.capped && delta > 0 ? "That's as firm as I can safely go here." : line)
        case .pause?:
            // "Worse" is not "too strong": the session pauses and only resumes once it has settled.
            pauseForWorsening(note: "Paused: discomfort increased")
            say("Let's pause. \(Self.settleQuestion)")
        case .keepGoing(let line)?: say(line)
        case nil: break
        }
    }
    func pauseOrResume() {
        if pausedForWorse { return say(Self.settleQuestion) }     // no way round the check
        if step == .paused { resumeRun(gentler: false) } else { device.pause(); step = .paused; refresh() }
    }

    // MARK: - Worse during a session → check before going on
    static let settleQuestion = "Has it settled back to how it felt before the session?"
    private func pauseForWorsening(note: String) {
        if step == .treat { device.pause(); step = .paused }
        pausedForWorse = true; checkIn = false; adjustments.append(note); refresh()
    }
    /// It settled: carry on one level gentler.
    func settled() { guard pausedForWorse else { return }; resumeRun(gentler: true) }
    /// Still worse: end the session and go straight to the outcome as "worse".
    func stillWorse() {
        guard pausedForWorse else { return }
        stopTicker(); runResult = device.stop(); body.setPatches(around: []); checkIn = false; pausedForWorse = false
        stopReason = "Stopped: discomfort increased during the session and hadn't settled"
        finishReassessment("worse")
    }
    private func resumeRun(gentler: Bool) {
        if gentler, let rd = reading, let t = tri {
            let change = SafetyValidator.validateLevel(rd.level - 1, modality: rd.modality, t); device.setIntensity(change)
            adjustments.append("Resumed at level \(change.intensity) after it settled")
        }
        pausedForWorse = false; device.resume(); step = .treat; refresh()
        say(gentler ? "Carrying on more gently. Tell me straight away if it gets worse." : "Resuming.")
    }
    private func moveFocus(_ dir: String) {
        guard let s = sel, care?.point == true, let t = tri else { return say("This session covers the whole area, so there is nothing to move.") }
        refine(dir, slight: true, keepFlow: true)
        guard let new = sel, let change = SafetyValidator.validateRetarget(from: s.id, to: new.id, t) else { return say("I can only move the focus within the same area during a session.") }
        device.retarget(change); care?.id = new.id; placePatches()
        adjustments.append("Focus moved to \(atlas[new.id].label.lowercased())")
        say("Moved the focus \(["up": "higher", "down": "lower", "out": "further out", "in": "further in", "front": "toward the front", "back": "toward the back"][dir] ?? "").")
    }
    func endRun() {
        guard step == .treat || step == .paused else { return }
        stopTicker()
        if pausedForWorse && stopReason == nil { stopReason = "Stopped by the user after discomfort increased" }
        runResult = device.stop(); body.setPatches(around: []); checkIn = false; pausedForWorse = false
        if A.movementBefore != nil && !skipMovement {
            // Don't ask someone to repeat a movement that was uncomfortable before.
            if investigation.baseline?.isUncomfortable == true {
                investigation.addCheck(.movement, purpose: "Compare with before care", prompt: movementTest?.name ?? "Movement check",
                                       response: "Not repeated: it was uncomfortable before", status: .skipped)
                return reassessStep()
            }
            return movementStep("after")
        }
        reassessStep()
    }
    private func placePatches() {
        guard let c = care, let mesh = body.mesh else { return }
        var pts: [(SIMD3<Float>, SIMD3<Float>)] = []
        if c.point, let s = sel { pts.append((s.p, s.n)) } else if let r = mesh.representativePoint(of: c.id) { pts.append(r) }
        if let pr = c.pair, let r = mesh.representativePoint(of: pr) { pts.append(r) }
        body.setPatches(around: pts)
    }

    // MARK: - Reassess → learn / escalate
    private func reassessStep() { go(.reassess); say("All done. How does that feel now?") }
    func reassess(_ response: String) {
        guard step == .reassess else { return }      // a second tap must not reassess (or save) twice
        finishReassessment(response)
    }
    private func finishReassessment(_ response: String) {
        self.response = response
        let s = sym ?? AssessmentService.symptom(A)
        let comparison: TreatmentEngine.MovementComparison? = {
            guard let t = movementTest, let b = A.movementBefore, let a = A.movementAfter else { return nil }
            return .init(name: t.name, before: b, after: a)
        }()
        let newWarning = A.safetyFlags.count > flagsAtStart ? A.safetyFlags.last?.label : nil
        let r = TreatmentEngine.reassess(response: response, s, history: history, movement: comparison, newWarning: newWarning); result = r
        // A plausible, hedged "why it might feel this way", only when nothing points the other way.
        why = r.pathway == "review" || r.pathway == "escalate" ? ""
            : TreatmentEngine.explain(response: response, s, plan: validated?.plan, before: A.movementBefore, after: A.movementAfter)
        go(.outcome)
        saveEpisode()
        say(r.headline, speak: "\(r.headline) \(why)")
    }
    func saveRoutine() {
        guard let r = result, r.offerRoutine, !r.pausesAutomaticCare, let region = A.bodyRegion, let p = validated?.plan else { return }
        memory.saveRoutine(areaId: region, activity: A.activityContext, name: r.routineName, steps: p.steps); routineSaved = true
        say("Saved as your \(r.routineName.lowercased()). I'll suggest it next time.")
    }
    /// Saves this episode. Safe to call more than once: the same id updates the same record.
    private func saveEpisode() {
        let s = sym ?? AssessmentService.symptom(A)
        let spot = care?.point == true ? sel : nil
        let run = runResult
        let pathway = step == .stop ? (run == nil ? "not treated" : "stopped") : (result?.pathway ?? "")
        var e = Episode(id: episodeId, createdAt: startedAt, said: A.userDescription,
                        point: spot.map { [$0.p.x, $0.p.y, $0.p.z] }, normal: spot.map { [$0.n.x, $0.n.y, $0.n.z] },
                        symptom: .init(areaId: s.areaId ?? "body", pairId: s.pairId, side: s.side, type: s.type, severity: s.severity, onset: s.onset,
                                       activity: s.activity, triggers: s.triggers, atRest: s.atRest, previous: s.previous, flags: s.flags.map(\.label)),
                        triage: .init(level: tri?.level.rawValue ?? "ok", reasons: tri?.reasons ?? []),
                        outcome: .init(response: response, pathway: pathway, stopReason: stopReason,
                                       pausesAutomaticCare: result?.pausesAutomaticCare == true ? true : nil))
        if let run, let v = validated {
            e.intervention = .init(planName: v.plan.name, kind: v.plan.kind, steps: v.plan.steps, minutesPlanned: v.plan.minutes, durationSec: run.elapsed,
                                   patches: device.activePatches, adjustments: adjustments, safetyNotes: v.notes, log: run.log)
            e.outcome.sensors = BodyMemoryStore.summarise(run.log)
            e.outcome.lofersNote = why.isEmpty ? nil : why
        }
        e.feedback = feedbackLog
        e.investigation = investigation
        if let t = movementTest, A.movementBefore != nil { e.movement = .init(name: t.name, before: A.movementBefore, after: A.movementAfter) }
        memory.add(e)
    }

    // MARK: - Body selection (touch + voice share these)
    enum Target { case id(String), ask(PendingSide) }
    private func resolve(_ r: ParsedUtterance, _ e: ParsedUtterance.PartEntry) -> Target? {
        let side = r.side ?? (step == .listening ? nil : currentSide)
        if let tmpl = e.template, let side { return .id(tmpl.replacingOccurrences(of: "{s}", with: side.rawValue)) }
        if let tmpl = e.template, r.bilateral || A.laterality == "both" { return .ask(PendingSide(template: tmpl, noun: e.noun ?? "side", both: true)) }
        if let id = e.id { return .id(id) }
        if let tmpl = e.template { return .ask(PendingSide(template: tmpl, noun: e.noun ?? "side", both: false)) }
        return nil
    }
    private var currentSide: BodySide? { [sel?.id, cand, lit.first, focus].compactMap { $0 }.compactMap { atlas.node($0)?.side }.first }

    /// Show a place the user mentioned on the body; the conversation decides what Lofer says next.
    func applyTarget(_ target: Target, advanceAfter: Bool = true) async {
        switch target {
        case .ask(let ps):
            let a = ps.template.replacingOccurrences(of: "{s}", with: "r"), b = ps.template.replacingOccurrences(of: "{s}", with: "l")
            focus = atlas.lca(a, b); cand = nil; sel = nil; lit = [a, b]; pendingSide = ps; care = nil
            body.frame(focus, role: .select, turn: true); refresh()
            if advanceAfter { advance() }
        case .id(let id):
            pendingSide = nil
            if atlas.isLeaf(id), let rp = body.mesh?.representativePoint(of: id) {
                body.frame(atlas[id].parent!, role: role, turn: false)
                select(id, rp.point, rp.normal, keepCare: true)
            } else { focus = id; cand = nil; sel = nil; lit = [id]; care = nil; body.frame(id, role: .select, turn: true) }
            let changed = AssessmentService.setRegion(&A, id)
            A.specificArea = Self.surface(of: id) ?? A.specificArea      // "back of the shoulder" → back
            refresh()
            if advanceAfter { advance(changed ? ["region"] : []) }
        }
    }
    func chooseSide(_ s: BodySide) { if let ps = pendingSide { Task { await applyTarget(.id(ps.template.replacingOccurrences(of: "{s}", with: s.rawValue))) } } }

    func goFocus(_ id: String) {
        focus = id; cand = nil; sel = nil; lit = []; pendingSide = nil; care = nil
        body.frame(id, role: .select, turn: true); refresh()
        say(id == "body" ? "Show me where it's bothering you." : "\(atlas[id].label). Where exactly?")
    }
    func preview(_ id: String) {
        cand = id; sel = nil; lit = []; pendingSide = nil; refresh()
        say(atlas.isLeaf(id) ? "\(AssessmentService.cap(atlas[id].spoken))?" : "\(atlas[id].label). Zoom in, or choose the whole area.")
    }
    func zoomIn(_ id: String) { goFocus(id) }
    func pickChild(_ id: String) {
        if atlas.isLeaf(id), let rp = body.mesh?.representativePoint(of: id) { select(id, rp.point, rp.normal); say("Here? \(AssessmentService.cap(atlas[id].spoken)).") }
        else { preview(id) }
    }
    private func select(_ id: String, _ p: SIMD3<Float>, _ n: SIMD3<Float>, keepCare: Bool = false) {
        let parent = atlas[id].parent ?? "body"
        let changed = parent != focus
        sel = Spot(id: id, p: p, n: n); cand = nil; lit = []; pendingSide = nil; focus = parent
        if !keepCare { care = nil }
        if changed { body.frame(parent, role: role, turn: false) }
        body.face(normal: n, at: p)
        refresh()
    }
    /// A tap on the body. Once a spot exists (or the place is being checked), the tap moves the spot there.
    private func tapped(_ p: SIMD3<Float>, _ n: SIMD3<Float>) {
        guard [.locate, .listening, .clarify, .confirm, .correct].contains(step) else { return }
        if sel != nil || care != nil || [.clarify, .confirm, .correct].contains(step) { return moveSpot(to: p, n) }
        let L = BodySDF.classify(p, n), path = atlas.path(to: L)
        let base = path.contains(focus) ? focus : atlas.lca(focus, L)
        if base != focus { focus = base; body.frame(base, role: .select, turn: true) }
        guard let i = path.firstIndex(of: base), i + 1 < path.count else { return }
        let next = path[i + 1]
        if next == L { select(L, p, n); return say("Here? \(AssessmentService.cap(atlas[L].spoken)).") }
        if cand == next { return zoomIn(next) }
        preview(next)
    }
    private func moveSpot(to p: SIMD3<Float>, _ n: SIMD3<Float>) {
        let L = BodySDF.classify(p, n), wasConfirmed = care != nil
        select(L, p, n, keepCare: true)
        if wasConfirmed { care = Care(id: L, point: true) }
        AssessmentService.setRegion(&A, L, confirmed: wasConfirmed)
        if step == .confirm { refresh(); return say(confirmLine) }
        if [.locate, .listening].contains(step) { say("Here? \(AssessmentService.cap(atlas[L].spoken)).") }
    }
    /// ↑ ↓ ← → pad: nudges the spot in SCREEN directions, so it moves the way the user sees it.
    func nudge(dx: Float, dy: Float) {
        guard let s = sel else { return }
        let ax = body.screenAxes()
        let q = BodySDF.snap(s.p + ax.right * dx * 0.022 + ax.up * dy * 0.022)
        moveSpot(to: q.point, q.normal)
    }
    /// Voice directions ("a bit lower", "more towards the back").
    func refine(_ dir: String, slight: Bool, keepFlow: Bool = false) {
        guard let mesh = body.mesh else { return }
        if sel == nil {
            // Only a whole area is lit → pick the part of it that lies that way.
            let area = cand ?? lit.first ?? focus
            let sx: Float = (mesh.stats[area]?.center.x ?? 1) >= 0 ? 1 : -1
            let score: (BodyMesh.AreaStats) -> Float = ["up": { $0.center.y }, "down": { -$0.center.y }, "front": { $0.normal.z }, "back": { -$0.normal.z },
                                                        "out": { $0.normal.x * sx }, "in": { -$0.normal.x * sx }, "L": { $0.center.x }, "R": { -$0.center.x }][dir] ?? { $0.center.y }
            guard let pick = atlas.leaves(of: area).filter({ mesh.stats[$0] != nil }).max(by: { score(mesh.stats[$0]!) < score(mesh.stats[$1]!) }),
                  let rp = mesh.representativePoint(of: pick) else { return }
            select(pick, rp.point, rp.normal, keepCare: keepFlow)
            if !keepFlow { say("Here? \(AssessmentService.cap(atlas[pick].spoken)).") }
            return
        }
        let s = sel!, sx: Float = s.p.x >= 0 ? 1 : -1
        let v: SIMD3<Float> = ["up": [0, 1, 0], "down": [0, -1, 0], "out": [sx, 0, 0], "in": [-sx, 0, 0], "front": [0, 0, 1], "back": [0, 0, -1], "L": [1, 0, 0], "R": [-1, 0, 0]][dir] ?? .zero
        let step: Float = dir == "front" || dir == "back" ? (slight ? 0.05 : 0.08) : (slight ? 0.026 : 0.045)
        let q = BodySDF.snap(s.p + v * step)
        let L = BodySDF.classify(q.point, q.normal)
        select(L, q.point, q.normal, keepCare: keepFlow)
        if !keepFlow { say(L == s.id ? "A little \(["down": "lower", "up": "higher", "out": "further out", "in": "further in", "front": "toward the front", "back": "toward the back"][dir] ?? "over"). Here?" : "Here? \(AssessmentService.cap(atlas[L].spoken)).") }
    }
    func confirmSpot() { guard let s = sel else { return }; care = Care(id: s.id, point: true); regionConfirmed(s.id) }
    func confirmArea(_ id: String) { care = Care(id: id, point: false); cand = nil; sel = nil; lit = []; pendingSide = nil; if !atlas.isLeaf(id) { body.frame(id, role: role, turn: true) }; regionConfirmed(id) }
    func confirmBoth(_ tmpl: String) {
        let a = tmpl.replacingOccurrences(of: "{s}", with: "r"), b = tmpl.replacingOccurrences(of: "{s}", with: "l")
        care = Care(id: a, point: false, pair: b); cand = nil; sel = nil; lit = [a, b]; pendingSide = nil
        regionConfirmed(a, pair: b)
    }
    private func regionConfirmed(_ id: String, pair: String? = nil) {
        let changed = AssessmentService.setRegion(&A, id, pair: pair, confirmed: true)
        let label = atlas[id].label + (pair.map { " and \(atlas[$0].label.lowercased())" } ?? "")
        investigation.addCheck(.location, purpose: "Pin down the exact area", prompt: locatePrompt, response: label, status: .answered)
        investigation.addEvidence(.location, "Confirmed on the body: \(label)", field: "region", value: id)
        A.specificArea = A.specificArea ?? Self.surface(of: id)
        pendingInput = CareInput(kind: .location, text: label, field: "region", value: id)
        locatePromptOverride = nil
        advance(changed ? ["region"] : [])
    }

    /// "Back", "front", "outer"… from an atlas id like "r_sh_back".
    static func surface(of id: String) -> String? {
        for (k, v) in [("back", "back"), ("front", "front"), ("outer", "outer"), ("inner", "inner"), ("top", "top")] where id.hasSuffix("_\(k)") { return v }
        return nil
    }

    /// ← always means "back one step".
    func goBack() {
        switch step {
        case .treat, .paused: return endRun()
        case .outcome, .stop: return onExit?() ?? ()
        case .reassess: return
        case .movement where movementPhase == "after": return
        case .locate, .listening:
            if care != nil { care = nil; refresh(); return say("Okay. Adjust it, or tap somewhere else.") }
            if cand != nil || sel != nil || !lit.isEmpty || pendingSide != nil { cand = nil; sel = nil; lit = []; pendingSide = nil; refresh(); return say("Okay. Tap where it bothers you.") }
            if focus == "body" { return onExit?() ?? () }
            return goFocus(atlas[focus].parent ?? "body")
        default:
            let prev = trail.popLast() ?? .locate
            step = prev
            if prev == .locate || prev == .listening { care = nil; A.regionConfirmed = false }
            refresh()
            say(prev == .clarify ? (question?.text ?? "") : prev == .confirm ? confirmLine : prev == .movement ? (movementTest?.intro ?? "") : prev == .suggest ? "Here’s what I’d suggest." : locatePrompt)
        }
    }

    // MARK: - Body view tools
    var limb: String? { atlas.path(to: focus).first { $0.has("^[rl]_(arm|leg)$") } }
    func setLimbView(_ v: String?) { limbView = limbView == v ? nil : v; body.setLimbView(limbView, limb: limb) }
    func resetView() { limbView = nil; body.resetView() }

    // MARK: - Keeping the body in sync with the conversation
    var role: BodyRole {
        switch step {
        case .locate, .listening: return .select
        case .treat, .paused: return .treat
        case .clarify: return .clarify
        case .confirm, .correct: return .confirm
        case .movement: return .movement
        case .suggest, .custom, .stop: return .suggest
        case .reassess, .outcome: return .result
        }
    }
    func refresh() {
        guard bodyReady, let mesh = body.mesh else { return }
        var states = [Float](repeating: 0, count: atlas.leaves.count)
        for (i, c) in atlas[focus].children.filter({ mesh.hasArea($0) }).enumerated() {
            for l in atlas.leaves(of: c) { if let k = atlas.leafIndex[l] { states[k] = i % 2 == 1 ? 1.28 : 1 } }
        }
        func setAll(_ id: String, _ v: Float) { for l in atlas.leaves(of: id) { if let k = atlas.leafIndex[l] { states[k] = v } } }
        lit.forEach { setAll($0, 2.2) }
        if let c = cand { setAll(c, 2.2) }
        if let c = care, !c.point { setAll(c.id, 2.2); if let p = c.pair { setAll(p, 2.2) } }
        if let s = sel, let k = atlas.leafIndex[s.id] { states[k] = 3 }
        if let c = care, step == .treat || step == .paused { setAll(c.id, 2.3); if let p = c.pair { setAll(p, 2.3) } }
        body.setHighlights(states)
        body.setSpot(sel.map { $0.p }, normal: sel.map { $0.n })
        body.frame(focus, role: role, turn: false)
    }

    // MARK: - Speaking
    /// Everything Lofer says appears in the information zone and goes through the voice agent.
    func say(_ parts: String..., speak: String? = nil) {
        let text = parts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return }
        heard = ""                        // one message at a time
        withAnimation(.easeOut(duration: 0.25)) { agentLine = text }
        voice.speak(speak ?? text)
    }
}
