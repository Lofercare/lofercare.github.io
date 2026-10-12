# Phase 2 + 3: investigation-led care (mock intelligence)

Physical care is an information problem before it's an actuation problem. Lofer now gathers
evidence and reduces uncertainty before deciding whether conservative care is reasonable, and
it can decide not to treat. Everything runs end to end without a real LLM.

## Architecture

```
USER (voice / typing / taps on the body / movement answers)
  │
  ▼
CareFlowModel  (iOS: orchestration + existing screens; conversation drives the UI)
  │  CareRequest: latest input, recent conversation, AssessmentState, selected region,
  │  InvestigationState, movement observations, ≤3 relevant Body Memory summaries, step
  ▼
CareIntelligenceService ──► APICareIntelligenceService ──HTTP──► backend POST /api/care
  │   (falls back to LocalCareIntelligenceService on any failure)      │ zod-validated in/out
  │                                                                    ▼
  │                                                     CareIntelligenceProvider
  │                                                     ├─ OpenAICareIntelligenceProvider (gpt-5.4-mini)
  │                                                     └─ MockCareIntelligenceProvider (tests, no key)
  ▼  CareIntelligenceResponse: extracted info, assessment updates, possible contributing
  │  patterns, uncertainties, evidence, PROPOSED next action, readiness, wording
  ▼
AssessmentService.update   (deterministic merge into AssessmentState; on-device parser
  │                         still reads warning signs + UI commands every turn)
  ▼
InvestigationEngine.decide (deterministic: safety → conservative endings → budget →
  │                         validate proposal → otherwise its own next step)
  ▼
question · refine spot · movement check · observation ──► (loop)
proceed to care ─► confirm summary ─► SafetyValidator.triage ─► TreatmentEngine ─►
  SafetyValidator.validate (sealed command) ─► MockLoferDevice ─► same movement again ─►
  reassess ─► Body Memory (state → investigation → observation → intervention → outcome)
not enough information / professional / safety stop ─► stop screen (no care)
```

## What stays deterministic
- **SafetyValidator**: triage and plan validation; the only maker of device commands.
- **InvestigationEngine**: final say on the next action; budget (≤7 rounds, ≤3 questions plus the
  safety check, ≤2 location refinements, 1 baseline movement, 1 observation); never re-asks a known
  fact; never repeats an uncomfortable movement; "proceed" only when the area is confirmed, the
  feeling is known, warning signs are ruled out and the movement response is observed.
- **TreatmentEngine**: plans (modes, levels, minutes). Investigation context only shapes wording.
- **On-device warning-sign and command parsing** on every turn (safety never needs the network).
- **Language guard** (`CareLanguage`): provider wording that diagnoses is replaced.

## What the future LLM replaces
Only the backend's `MockCareIntelligenceProvider` (extraction, uncertainties, patterns, the
proposed action and its wording). Same interface, same schema; nothing in the app changes.

## Files
- iOS: `Models/Investigation.swift`, `Services/Intelligence/CareSchema.swift`,
  `InvestigationEngine.swift`, `CareIntelligenceService.swift`, `APICareIntelligenceService.swift`;
  changes in `CareFlowModel.swift`, `AssessmentState.swift`, `Episode.swift`, `BodyMemoryStore.swift`,
  `TreatmentEngine.swift`, `ResultSheets.swift`, `AppModel.swift`.
- Backend: `backend/` (see backend/README.md).
- Tests: `LoferTests/InvestigationTests.swift`, `CareNetworkingTests.swift`,
  `EndToEndBackendTests.swift` (needs `npm start`), `backend/tests/`.

## Known limitations
- The mock provider is keyword rules: it handles the documented scenarios, not open-ended language.
- Movement checks and observations are self-reported; no sensor data yet.
- Contributing patterns are produced only by the backend provider (the on-device fallback has none).
- Treatment plans still include compression and EMS, which the current hardware drawings don't show.
- Pause on automatic care has no expiry (see CARE-FLOW-POLICY.md).
