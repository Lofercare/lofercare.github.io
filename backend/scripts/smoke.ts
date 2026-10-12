// Live smoke test of the configured provider (costs a few cents with a real LLM):
//   npm run smoke
// Sends the tennis story, then a confirmed spot, and prints what came back and how long it took.
import { createProvider } from '../src/providers/index.ts';
import { CareIntelligenceResponse } from '../src/schemas/care.ts';

const TENNIS = "I played tennis for two hours yesterday. The back of my right shoulder started feeling tight afterwards. It's mostly okay normally but hurts a little when I lift my arm above my head.";
const A = { regionConfirmed: false, userDescription: [], movementTriggers: [], relievingFactors: [], safetyFlags: [], uncertainSigns: [], answers: {}, questionsAsked: 0 };
const inv = { patterns: [], uncertainties: [], evidence: [], checks: [], movementObservations: [], readiness: { informationSufficiency: 'insufficient' as const, reason: '' }, cycles: 0, intelligenceSources: [] };

const provider = createProvider();
const started = Date.now();
const r = await provider.respond({
  schemaVersion: 1, requestId: 'smoke-1', sessionId: 'smoke', turn: 1, latestUserInput: { kind: 'utterance', text: TENNIS }, expectedField: 'story',
  conversationHistory: [{ role: 'user', text: TENNIS }], currentAssessmentState: A, selectedBodyRegion: null, investigation: inv,
  completedMovementChecks: [], relevantBodyMemory: [], currentCareFlowState: 'listening',
});
console.log(`provider ${provider.name} · ${Date.now() - started} ms · valid ${CareIntelligenceResponse.safeParse(r).success}`);
console.log(JSON.stringify({ extracted: r.extractedInformation, updates: r.assessmentUpdates, next: r.recommendedNextAction,
  say: r.userFacingResponse, patterns: r.possibleContributingPatterns.map((p) => `${p.label} (${p.status})`) }, null, 2));
