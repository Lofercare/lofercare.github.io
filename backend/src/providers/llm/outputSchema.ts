// What an LLM is asked to produce, and how it becomes a CareIntelligenceResponse.
//
// Strict structured-output modes (OpenAI, and similar elsewhere) require every field to be
// present, with `null` for "nothing", and no open-ended objects. So the model gets this
// LLM-shaped schema; `toCareResponse` turns its answer into the app's contract, which the
// backend then validates again (src/schemas/care.ts) before anything reaches the app.
// Provider-neutral: a future Claude provider can reuse it unchanged.
import { z } from 'zod';
import { SCHEMA_VERSION, FlagLevel, MovementFeel, CareIntelligenceResponse } from '../../schemas/care.ts';
import type { CareRequest } from '../../schemas/care.ts';

const str = z.string();
const nstr = z.string().nullable();
const nbool = z.boolean().nullable();
const option = z.object({ label: str, value: str });

const action = z.union([
  z.object({ type: z.literal('askQuestion'), field: str, question: str, purpose: str, options: z.array(option).nullable(), multiSelect: nbool }),
  z.object({ type: z.literal('refineBodyLocation'), broadRegion: str, currentSelection: nstr,
             requestedRefinement: z.enum(['region', 'side', 'surface', 'precise']), prompt: str, purpose: str }),
  z.object({ type: z.literal('movementCheck'), movementId: str, phase: z.enum(['baseline', 'repeatCheck']), purpose: str, targetObservation: str }),
  z.object({ type: z.literal('requestUserObservation'), observationId: str, prompt: str, purpose: str, options: z.array(option) }),
  z.object({ type: z.literal('proceedToCare'), reason: str }),
  z.object({ type: z.literal('insufficientInformation'), reason: str, message: str }),
  z.object({ type: z.literal('recommendProfessionalAssessment'), reason: str, message: str }),
  z.object({ type: z.literal('safetyStop'), reason: str, urgent: z.boolean() }),
]);

export const LLMCareOutput = z.object({
  extractedInformation: z.object({
    bodyMention: z.object({ regionId: nstr, template: nstr, noun: nstr }).nullable(),
    side: z.enum(['left', 'right']).nullable(),
    bilateral: nbool,
    warningSigns: z.array(z.object({ level: FlagLevel, label: str, status: z.enum(['reported', 'negated', 'uncertain']) })),
    confirm: nbool, deny: nbool, unsure: nbool, skip: nbool,
    direction: z.enum(['up', 'down', 'front', 'back', 'out', 'in', 'L', 'R']).nullable(),
    slight: nbool,
    movementResult: z.object({ feel: MovementFeel, whereInMovement: nstr, quality: nstr, sideOfIt: nstr }).nullable(),
    observation: option.nullable(),
  }),
  assessmentUpdates: z.object({
    sensation: z.enum(['tightness', 'soreness', 'ache', 'sharp', 'burning', 'cramp', 'unclear', 'pain']).nullable(),
    severity: z.number().int().nullable(),
    onset: z.enum(['today', 'last night', 'yesterday', 'a few days ago', 'weeks ago', 'months ago']).nullable(),
    onsetType: z.enum(['sudden', 'gradual']).nullable(),
    activityContext: nstr,
    activityDuration: nstr,
    symptomsAtRest: z.enum(['minimal', 'present']).nullable(),
    progression: z.enum(['improving', 'stable', 'worsening']).nullable(),
    previousEpisodes: nbool,
    movementTriggers: z.array(str).nullable(),
    relievingFactors: z.array(str).nullable(),
    specificArea: z.enum(['front', 'back', 'outer', 'inner', 'top']).nullable(),
  }),
  possibleContributingPatterns: z.array(z.object({
    id: str, label: str, status: z.enum(['possible', 'supported', 'weakened']), supporting: z.array(str), weakening: z.array(str),
  })),
  uncertainties: z.array(z.object({ id: str, topic: str, importance: z.enum(['high', 'medium', 'low']), field: nstr })),
  evidenceUpdates: z.array(z.object({ summary: str, field: nstr, value: nstr, supports: z.array(str), weakens: z.array(str) })),
  recommendedNextAction: action,
  readiness: z.object({ informationSufficiency: z.enum(['insufficient', 'partial', 'sufficient']), reason: str }),
  userFacingResponse: z.object({ acknowledgement: str, prompt: str }),
});
export type LLMCareOutput = z.infer<typeof LLMCareOutput>;

/** LLMCareOutput as a JSON Schema that strict structured-output modes accept. */
export function strictJsonSchema(): Record<string, unknown> {
  const schema = z.toJSONSchema(LLMCareOutput) as Record<string, unknown>;
  delete schema.$schema;
  return makeStrict(schema) as Record<string, unknown>;
}
/** Every object: all properties required, no extras. Drop keywords strict modes may reject. */
function makeStrict(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(makeStrict);
  if (!node || typeof node !== 'object') return node;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(node)) {
    if (['minLength', 'maxLength', 'minItems', 'maxItems', 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'pattern', 'format'].includes(k)) continue;
    out[k === 'oneOf' ? 'anyOf' : k] = makeStrict(v);
  }
  if (out.type === 'object' && out.properties && typeof out.properties === 'object') {
    out.required = Object.keys(out.properties as object);
    out.additionalProperties = false;
  }
  return out;
}

/** The model's answer → the app's CareIntelligenceResponse (still validated afterwards). */
export function toCareResponse(raw: unknown, request: CareRequest, provider: string): CareIntelligenceResponse {
  const o = LLMCareOutput.parse(raw);
  const at = new Date().toISOString();
  const a = o.recommendedNextAction;
  return CareIntelligenceResponse.parse({
    schemaVersion: SCHEMA_VERSION,
    requestId: request.requestId,
    provider,
    extractedInformation: o.extractedInformation,
    assessmentUpdates: {
      ...o.assessmentUpdates,
      severity: o.assessmentUpdates.severity === null ? null : Math.max(0, Math.min(10, o.assessmentUpdates.severity)),
    },
    possibleContributingPatterns: o.possibleContributingPatterns,
    uncertainties: o.uncertainties,
    evidenceUpdates: o.evidenceUpdates.map((e, i) => ({ id: `llm-${request.turn}-${i + 1}`, source: 'careIntelligence', at, ...e })),
    recommendedNextAction: a.type === 'askQuestion' && a.options?.length === 0 ? { ...a, options: null } : a,
    readiness: o.readiness,
    userFacingResponse: { acknowledgement: o.userFacingResponse.acknowledgement.slice(0, 280), prompt: o.userFacingResponse.prompt.slice(0, 280) },
  });
}
