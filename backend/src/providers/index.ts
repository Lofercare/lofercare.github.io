// Chooses the Care Intelligence provider from the environment (CARE_PROVIDER).
//   mock    deterministic rules (no keys; used by tests)
//   openai  an OpenAI model (needs OPENAI_API_KEY; OPENAI_MODEL and OPENAI_REASONING_EFFORT optional)
import type { CareIntelligenceProvider } from './CareIntelligenceProvider.ts';
import { MockCareIntelligenceProvider } from './mock/MockCareIntelligenceProvider.ts';
import { OpenAICareIntelligenceProvider } from './openai/OpenAICareIntelligenceProvider.ts';
import type OpenAI from 'openai';

export function createProvider(name = process.env.CARE_PROVIDER ?? 'mock'): CareIntelligenceProvider {
  switch (name) {
    case 'mock':
      return new MockCareIntelligenceProvider();
    case 'openai':
      if (!process.env.OPENAI_API_KEY) throw new Error('CARE_PROVIDER=openai needs OPENAI_API_KEY in backend/.env');
      return new OpenAICareIntelligenceProvider({
        model: process.env.OPENAI_MODEL || undefined,
        reasoningEffort: (process.env.OPENAI_REASONING_EFFORT as OpenAI.ReasoningEffort) || undefined,
      });
    default:
      throw new Error(`Care provider "${name}" isn't implemented. Use CARE_PROVIDER=mock or openai.`);
  }
}
