import Foundation

// THE CARE INTELLIGENCE CONTRACT — what the app sends each turn and what comes back.
// Mirrors backend/src/schemas/care.ts field for field (camelCase JSON, ISO-8601 dates).
// Bump `CareSchema.version` on both sides when the shape changes.

enum CareSchema {
    static let version = 1
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// What the user just did: said or typed something, tapped an answer, confirmed a
/// spot on the body, reported how a movement felt, or answered an observation.
struct CareInput: Codable, Equatable {
    enum Kind: String, Codable { case utterance, answer, location, movementResult, observation }
    var kind: Kind
    var text: String? = nil        // their words (or the tapped label)
    var field: String? = nil       // which question/observation it answers
    var value: String? = nil       // the structured value
}

struct ConversationTurn: Codable, Equatable {
    enum Role: String, Codable { case user, lofer }
    var role: Role
    var text: String
}

struct SelectedRegion: Codable, Equatable {
    var id: String                 // atlas id, e.g. "r_sh_back"
    var label: String              // "Back of right shoulder"
    var group: String              // joint/segment, e.g. "r_shoulder"
    var laterality: String?        // left / right / both / centre
    var confirmed: Bool            // the user confirmed the spot
    var isLeaf: Bool               // a precise area (not a whole region)
}

/// A short summary of an earlier, relevant session (never the whole Body Memory).
struct MemorySummary: Codable, Equatable {
    var date: Date
    var area: String
    var activity: String?
    var sensation: String?
    var movement: String?          // "Arm raise: a little uncomfortable → fine"
    var intervention: String?      // "Gentle shoulder recovery, 10 min"
    var response: String?          // much / little / same / worse
    var pausedAutomaticCare: Bool
}

/// Sent to POST /api/care.
struct CareRequest: Codable, Equatable {
    var schemaVersion = CareSchema.version
    var requestId: String
    var sessionId: String
    var turn: Int
    var latestUserInput: CareInput
    var expectedField: String?                 // what Lofer last asked about, if anything
    var conversationHistory: [ConversationTurn] // recent turns only
    var currentAssessmentState: AssessmentState
    var selectedBodyRegion: SelectedRegion?
    var investigation: InvestigationState
    var completedMovementChecks: [MovementObservation]
    var relevantBodyMemory: [MemorySummary]
    var currentCareFlowState: String
}

/// A warning sign as the user put it: reported, ruled out, or unsure.
struct WarningSign: Codable, Equatable {
    enum Status: String, Codable { case reported, negated, uncertain }
    var level: FlagLevel
    var label: String
    var status: Status
}

/// Where on the body the user mentioned (atlas ids / templates; "{s}" = side).
struct BodyMention: Codable, Equatable {
    var regionId: String? = nil
    var template: String? = nil
    var noun: String? = nil
}

/// What this one input said, in structured form.
struct ExtractedInformation: Codable, Equatable {
    var bodyMention: BodyMention? = nil
    var side: String? = nil                    // left / right
    var bilateral: Bool? = nil
    var warningSigns: [WarningSign] = []
    var confirm: Bool? = nil
    var deny: Bool? = nil
    var unsure: Bool? = nil
    var skip: Bool? = nil
    var direction: String? = nil               // up / down / front / back / out / in / L / R
    var slight: Bool? = nil
    var movementResult: MovementResult? = nil  // if this input described how a movement felt
    var observation: ActionOption? = nil       // answer to an observation request (label, value)
}

/// Suggested changes to the cumulative assessment. The app merges these
/// deterministically and never lets them overwrite what the user said.
struct AssessmentPatch: Codable, Equatable {
    var sensation: String? = nil
    var severity: Int? = nil
    var onset: String? = nil
    var onsetType: String? = nil
    var activityContext: String? = nil
    var activityDuration: String? = nil
    var symptomsAtRest: String? = nil          // minimal / present
    var progression: String? = nil             // improving / stable / worsening
    var previousEpisodes: Bool? = nil
    var movementTriggers: [String]? = nil
    var relievingFactors: [String]? = nil
    var specificArea: String? = nil            // front / back / outer / inner / top
}

struct UserFacingResponse: Codable, Equatable {
    var acknowledgement: String                // "Got it, it started after tennis."
    var prompt: String                         // the one next step, in Lofer's voice
}

/// Returned by POST /api/care. Structured data, not chatbot prose.
struct CareIntelligenceResponse: Codable, Equatable {
    var schemaVersion: Int
    var requestId: String
    var provider: String                       // "mock", "local", later e.g. "anthropic"
    var extractedInformation: ExtractedInformation
    var assessmentUpdates: AssessmentPatch
    var possibleContributingPatterns: [ContributingPattern]
    var uncertainties: [Uncertainty]
    var evidenceUpdates: [Evidence]
    var recommendedNextAction: InvestigationAction
    var readiness: Readiness
    var userFacingResponse: UserFacingResponse
}

// MARK: - Bridging to the existing on-device model

extension ParsedUtterance {
    /// One utterance as Care Intelligence understood it, merged with the on-device
    /// reading of the same words. Care fields come from Care Intelligence when it has
    /// them; warning signs are UNIONED, so neither side can quietly drop one; UI
    /// commands ("start", "too strong", "much better") stay on-device.
    static func merged(local: ParsedUtterance, with response: CareIntelligenceResponse?) -> ParsedUtterance {
        guard let response else { return local }
        var r = local
        let x = response.extractedInformation, u = response.assessmentUpdates
        // Only body areas the app's atlas knows (an LLM could invent an id). Unknown ones are ignored.
        if let m = x.bodyMention {
            let atlas = BodyAtlas.shared
            let id = m.regionId.flatMap { atlas.node($0) != nil ? $0 : nil }
            let template = m.template.flatMap { t in atlas.node(t.replacingOccurrences(of: "{s}", with: "r")) != nil ? t : nil }
            if id != nil || template != nil { r.entry = .init(id: id, template: template, noun: m.noun) }
        }
        if let s = x.side { r.side = s == "left" ? .left : s == "right" ? .right : r.side }
        if x.bilateral == true { r.bilateral = true }
        if let v = u.sensation, AssessmentPatch.sensations.contains(v) { r.type = v }
        if let v = u.severity, (0...10).contains(v) { r.severity = v }
        if let v = u.onset, AssessmentService.onsetWords[v] != nil { r.onset = v }
        if let v = u.activityContext { r.activity = v }
        for t in u.movementTriggers ?? [] where !r.triggers.contains(t) { r.triggers.append(t) }
        if u.previousEpisodes == true { r.previous = true }
        if let v = u.activityDuration { r.story.activityDuration = v }
        if let v = u.symptomsAtRest, ["minimal", "present"].contains(v) { r.story.atRest = v }
        if let v = u.relievingFactors?.first { r.story.relieving = v }
        if let v = u.progression, ["improving", "stable", "worsening"].contains(v) { r.story.progression = v }
        if let v = u.onsetType, ["sudden", "gradual"].contains(v) { r.story.onsetType = v }
        func add(_ list: inout [SafetyFlag], _ s: WarningSign) { if !list.contains(where: { $0.label == s.label }) { list.append(.init(level: s.level, label: s.label)) } }
        for s in x.warningSigns {
            switch s.status {
            case .reported: add(&r.flags, s)
            case .uncertain: add(&r.uncertainFlags, s)
            case .negated: add(&r.negatedFlags, s)
            }
        }
        // A sign reported by either reader stays reported (the conservative choice).
        r.negatedFlags.removeAll { n in r.flags.contains { $0.label == n.label } || r.uncertainFlags.contains { $0.label == n.label } }
        if x.unsure == true { r.unsure = true }
        if x.skip == true { r.skip = true }
        if x.confirm == true { r.confirm = true }
        if x.deny == true { r.deny = true }
        if let d = x.direction { r.direction = d }
        if x.slight == true { r.slight = true }
        if let m = x.movementResult { r.movement = m }
        return r
    }
}

extension AssessmentPatch {
    static let sensations: Set<String> = ["tightness", "soreness", "ache", "sharp", "burning", "cramp", "unclear", "pain"]
}

extension ExtractedInformation {
    /// The on-device parser's reading, in the shared schema (used by the local service).
    init(_ r: ParsedUtterance) {
        self.init()
        if let e = r.entry { bodyMention = BodyMention(regionId: e.id, template: e.template, noun: e.noun) }
        side = r.side?.word
        bilateral = r.bilateral ? true : nil
        warningSigns = r.flags.map { .init(level: $0.level, label: $0.label, status: .reported) }
            + r.negatedFlags.map { .init(level: $0.level, label: $0.label, status: .negated) }
            + r.uncertainFlags.map { .init(level: $0.level, label: $0.label, status: .uncertain) }
        confirm = r.confirm ? true : nil; deny = r.deny ? true : nil; unsure = r.unsure ? true : nil; skip = r.skip ? true : nil
        direction = r.direction; slight = r.slight ? true : nil
        movementResult = r.movement
    }
}

extension AssessmentPatch {
    init(_ r: ParsedUtterance) {
        self.init(sensation: r.type, severity: r.severity, onset: r.onset, onsetType: r.story.onsetType, activityContext: r.activity,
                  activityDuration: r.story.activityDuration, symptomsAtRest: r.story.atRest, progression: r.story.progression,
                  previousEpisodes: r.previous ? true : nil, movementTriggers: r.triggers.isEmpty ? nil : r.triggers,
                  relievingFactors: r.story.relieving.map { [$0] }, specificArea: nil)
    }
}
