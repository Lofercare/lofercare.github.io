// OpenAICareIntelligenceProvider — Care Intelligence from an OpenAI model, behind the same
// CareIntelligenceProvider interface as the mock. It only returns structured understanding
// and a PROPOSED next step; the app's InvestigationEngine and SafetyValidator decide.
//
// Uses the Responses API with a strict JSON schema (structured outputs), so the model's
// answer always has the expected shape; it is then converted and validated again.
// The API key lives in backend/.env (OPENAI_API_KEY) and never reaches the iOS app.
import OpenAI from 'openai';
import type { CareIntelligenceProvider } from '../CareIntelligenceProvider.ts';
import type { CareRequest, CareIntelligenceResponse } from '../../schemas/care.ts';
import { strictJsonSchema, toCareResponse } from '../llm/outputSchema.ts';
import { SYSTEM_INSTRUCTIONS, turnInput } from '../llm/prompt.ts';

/** The part of the OpenAI client this provider uses (so tests can pass a fake). */
export interface ResponsesClient {
  responses: { create(params: OpenAI.Responses.ResponseCreateParamsNonStreaming, options?: { timeout?: number }): Promise<{ output_text: string; status?: string | null }> };
}

export interface OpenAIProviderOptions {
  model?: string;                                 // default: gpt-5.4-mini
  reasoningEffort?: OpenAI.ReasoningEffort;       // default: low (quick conversational turns)
  timeoutMs?: number;
  client?: ResponsesClient;                       // injected in tests
  apiKey?: string;
}

export class OpenAICareIntelligenceProvider implements CareIntelligenceProvider {
  readonly name = 'openai';
  readonly model: string;
  private readonly client: ResponsesClient;
  private readonly effort: OpenAI.ReasoningEffort;
  private readonly timeoutMs: number;
  private static schema = strictJsonSchema();

  constructor(options: OpenAIProviderOptions = {}) {
    this.model = options.model ?? 'gpt-5.4-mini';
    this.effort = options.reasoningEffort ?? 'low';
    this.timeoutMs = options.timeoutMs ?? 18_000;
    // maxRetries 0: a slow or failed turn should fall back quickly in the app, not retry for minutes.
    this.client = options.client ?? new OpenAI({ apiKey: options.apiKey, maxRetries: 0 });
  }

  async respond(request: CareRequest): Promise<CareIntelligenceResponse> {
    const response = await this.client.responses.create({
      model: this.model,
      instructions: SYSTEM_INSTRUCTIONS,
      input: turnInput(request),
      reasoning: { effort: this.effort },
      max_output_tokens: 4000,
      store: false,                                // don't keep health-related conversations on OpenAI's side
      text: { format: { type: 'json_schema', name: 'care_intelligence_response', schema: OpenAICareIntelligenceProvider.schema, strict: true } },
    }, { timeout: this.timeoutMs });

    if (response.status && response.status !== 'completed') throw new Error(`OpenAI response ${response.status}`);
    if (!response.output_text) throw new Error('OpenAI returned no structured output (possibly a refusal)');
    return toCareResponse(JSON.parse(response.output_text), request, this.name);
  }
}
