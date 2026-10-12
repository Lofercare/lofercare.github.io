// The OpenAI provider, with a fake client (no network, no key, no cost).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OpenAICareIntelligenceProvider, type ResponsesClient } from '../src/providers/openai/OpenAICareIntelligenceProvider.ts';
import { strictJsonSchema, type LLMCareOutput } from '../src/providers/llm/outputSchema.ts';
import { SYSTEM_INSTRUCTIONS, turnInput } from '../src/providers/llm/prompt.ts';
import { CareIntelligenceResponse } from '../src/schemas/care.ts';
import { request, TENNIS } from './helpers.ts';

const answer: LLMCareOutput = {
  extractedInformation: { bodyMention: { regionId: null, template: '{s}_sh_back', noun: 'shoulder' }, side: 'right', bilateral: null, warningSigns: [],
    confirm: null, deny: null, unsure: null, skip: null, direction: null, slight: null, movementResult: null, observation: null },
  assessmentUpdates: { sensation: 'tightness', severity: 2, onset: 'yesterday', onsetType: null, activityContext: 'tennis', activityDuration: 'two hours',
    symptomsAtRest: 'minimal', progression: null, previousEpisodes: null, movementTriggers: ['Raising the arm overhead'], relievingFactors: null, specificArea: 'back' },
  possibleContributingPatterns: [{ id: 'activity-load', label: 'Tightness after a demanding activity', status: 'possible', supporting: ['after tennis'], weakening: [] }],
  uncertainties: [{ id: 'precise-area', topic: 'The exact spot', importance: 'medium', field: null }],
  evidenceUpdates: [{ summary: 'Started after two hours of tennis', field: 'activityContext', value: 'tennis', supports: ['activity-load'], weakens: [] }],
  recommendedNextAction: { type: 'refineBodyLocation', broadRegion: 'shoulder', currentSelection: null, requestedRefinement: 'precise',
    prompt: "Show me where it's most noticeable.", purpose: 'Pin down the spot' },
  readiness: { informationSufficiency: 'partial', reason: 'Spot not confirmed' },
  userFacingResponse: { acknowledgement: 'Got it — it started after tennis yesterday.', prompt: "Show me where it's most noticeable." },
};
function fake(output: unknown, status = 'completed') {
  const calls: unknown[] = [];
  const client: ResponsesClient = { responses: { create: async (params) => { calls.push(params); return { output_text: typeof output === 'string' ? output : JSON.stringify(output), status }; } } };
  return { client, calls };
}

test('the strict schema: every object closed and fully required', () => {
  const walk = (n: unknown): void => {
    if (Array.isArray(n)) return n.forEach(walk);
    if (!n || typeof n !== 'object') return;
    const o = n as Record<string, unknown>;
    if (o.type === 'object' && o.properties) {
      assert.equal(o.additionalProperties, false);
      assert.deepEqual([...(o.required as string[])].sort(), Object.keys(o.properties as object).sort());
    }
    assert.ok(!('oneOf' in o), 'anyOf only');
    Object.values(o).forEach(walk);
  };
  walk(strictJsonSchema());
});

test('sends the instructions, context and strict format; converts the answer to the contract', async () => {
  const { client, calls } = fake(answer);
  const provider = new OpenAICareIntelligenceProvider({ client, model: 'test-model' });
  const req = request({ text: TENNIS, expectedField: 'story' });
  const r = await provider.respond(req);
  assert.ok(CareIntelligenceResponse.safeParse(r).success);
  assert.equal(r.provider, 'openai');
  assert.equal(r.requestId, req.requestId);
  assert.equal(r.evidenceUpdates[0].source, 'careIntelligence');
  const sent = calls[0] as { model: string; instructions: string; input: string; store: boolean; text: { format: { strict: boolean } } };
  assert.equal(sent.model, 'test-model');
  assert.equal(sent.instructions, SYSTEM_INSTRUCTIONS);
  assert.equal(sent.input, turnInput(req));
  assert.equal(sent.text.format.strict, true);
  assert.equal(sent.store, false, 'conversations are not stored at OpenAI');
});

test('refusals, incomplete or wrong-shaped answers throw (the app then falls back on-device)', async () => {
  const req = request({ text: TENNIS });
  await assert.rejects(new OpenAICareIntelligenceProvider({ client: fake('').client }).respond(req));
  await assert.rejects(new OpenAICareIntelligenceProvider({ client: fake(answer, 'incomplete').client }).respond(req));
  await assert.rejects(new OpenAICareIntelligenceProvider({ client: fake({ ...answer, recommendedNextAction: { type: 'setEMS', level: 9 } }).client }).respond(req));
  await assert.rejects(new OpenAICareIntelligenceProvider({ client: fake('{not json').client }).respond(req));
});

test('the context sent is trimmed, and instructions forbid diagnosis and device settings', () => {
  const long = request({ text: TENNIS, conversationHistory: Array.from({ length: 20 }, (_, i) => ({ role: 'user' as const, text: `turn ${i}` })) });
  const input = JSON.parse(turnInput(long));
  assert.equal(input.conversationHistory.length, 8);
  assert.match(SYSTEM_INSTRUCTIONS, /Diagnose/i);
  assert.match(SYSTEM_INSTRUCTIONS, /device settings/i);
});
