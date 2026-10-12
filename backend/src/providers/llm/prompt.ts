// Builds what an LLM provider sends: fixed instructions (identical every turn, so they can
// be cached) and the turn's context as compact JSON. Provider-neutral.
import { readFileSync } from 'node:fs';
import type { CareRequest } from '../../schemas/care.ts';
import { PARTS, FLAGS, TRIGGERS } from '../mock/extract.ts';
import { MOVEMENTS } from '../mock/MockCareIntelligenceProvider.ts';

const base = readFileSync(new URL('../../prompts/care-intelligence.md', import.meta.url), 'utf8')
  .replace(/^# .*\n+Status:[\s\S]*?\n\n/, ''); // drop the file's title and status note

const vocabulary = PARTS.map(([, e]) => [e.regionId, e.template].filter(Boolean).join(' / ')).filter((v, i, a) => a.indexOf(v) === i);

/** The fixed system instructions. */
export const SYSTEM_INSTRUCTIONS = `${base}

## How to fill the output
- extractedInformation describes ONLY the latest input. assessmentUpdates holds facts from the latest input
  that should be added to the assessment. Use null for anything not said. Never invent facts.
- bodyMention: copy ids and templates EXACTLY from this list, never make new ones ("{s}" is replaced by the side):
  ${vocabulary.join('; ')}.
  Pick the MOST SPECIFIC entry: "back of my shoulder" → template "{s}_sh_back"; "front of my shoulder" → "{s}_sh_front";
  just "shoulder" → "{s}_shoulder". Set regionId only when the list gives an id for that area; otherwise null.
  If the user names a side, also set "side". If no listed area fits, set bodyMention to null.
- movementTriggers: use these labels where one fits: ${TRIGGERS.map(([, l]) => l).join('; ')}.
- Only fill a field when the user actually said it. onsetType is "sudden" only for words like "suddenly" or
  "felt a pop"; "gradual" only for "gradually" or "built up". Otherwise null.
- severity is 0–10 ("a little" ≈ 2, "quite a lot" ≈ 6, "a lot" ≈ 7). onset uses the fixed buckets.
- symptomsAtRest: "minimal" when it's mostly fine at rest, "present" when it's there all the time.
- warningSigns: list every warning sign mentioned with status reported / negated ("no numbness") / uncertain
  ("not sure if it's numb"). Prefer these labels and levels: ${FLAGS.map(([lvl, , label]) => `${label} (${lvl})`).join('; ')}.
- activityContext: just the activity, as a short lowercase noun: "tennis", "running", "lifting", "sitting", "work".
  The duration goes in activityDuration ("two hours"). Never put a whole phrase in activityContext.
- movementResult: when currentCareFlowState is "movement", the latest input IS the result of the movement check that
  was just shown: always fill movementResult then. feel means how the movement felt NOW:
  fine = comfortable, easy, easier, no problem, looser · little = a bit uncomfortable, pulls partway, slightly tight ·
  quite = quite uncomfortable or painful · cannot = couldn't do it comfortably.
  Also note whereInMovement ("about halfway", "near the end of the movement") and quality ("pulling", "pinching").
- A movement check is DONE once its result is in the latest input or in completedMovementChecks: never propose the
  same movementCheck again. After a mildDiscomfort result, the next step is usually requestUserObservation.
- observation: only when expectedField starts with "observation:" — map their answer to one of the offered options.
- movementCheck ids (only these exist): ${MOVEMENTS.map((m) => `${m.id} (${m.name})`).join(', ')}. Use the one that matches the area.
- requestUserObservation: use observationId "eases_when_stopped" to ask whether it settled when the movement stopped,
  with options [{"label":"Yes, it eased","value":"eased"},{"label":"It lingered","value":"lingered"},{"label":"Not sure","value":"unsure"}].
- askQuestion field: one of sensation, safety, triggers, onset, severity, previous, or a short new field name.
  For "safety", the app shows its own checklist.

## Decision policy (the app's engine enforces it too; proposals that break it are replaced)
1. Any reported stop/urgent warning sign → safetyStop (urgent if any is urgent).
2. Present at rest AND lasting months or getting worse → recommendProfessionalAssessment.
3. Still no area or feeling after a couple of rounds, or investigation.cycles ≥ 6 → insufficientInformation.
4. No area → refineBodyLocation (region). A side template with no side → refineBodyLocation (side).
5. Warning signs not ruled out when there's a reason to check (sharp/burning, severity ≥ 7, at rest, months,
   worsening, or an uncertain sign) and the safety question isn't answered → askQuestion field "safety".
6. Feeling unknown → askQuestion "sensation". 7. Area not confirmed (selectedBodyRegion.confirmed false) →
   refineBodyLocation (precise). 8. A movement exists and no baseline is in completedMovementChecks → movementCheck.
9. Baseline was mildDiscomfort and the observation isn't done → requestUserObservation.
10. Otherwise → proceedToCare, with the reason in plain words.
Never ask about something already in currentAssessmentState or answered in investigation.checks.

## Voice
acknowledgement: ONE complete sentence showing you listened, e.g. "Got it — it started after tennis yesterday,
and you're feeling it at the back of your right shoulder." (empty string is fine after a tap).
prompt: ONE complete sentence with the next step, starting with a capital letter. The two are shown one after the
other, so never split a sentence between them. Each under 160 characters. British English.
For refineBodyLocation "precise" when the area is already known, the prompt is simply
"Show me where it's most noticeable." — never re-ask front/back/side the user already gave.
No diagnosis, no device settings, no "as an AI".`;

/** The turn's context, trimmed to what matters (never the whole Body Memory or every evidence item). */
export function turnInput(r: CareRequest): string {
  const A = r.currentAssessmentState;
  const inv = r.investigation;
  return JSON.stringify({
    latestUserInput: r.latestUserInput,
    expectedField: r.expectedField ?? null,
    currentCareFlowState: r.currentCareFlowState,
    turn: r.turn,
    conversationHistory: r.conversationHistory.slice(-8),
    currentAssessmentState: { ...A, userDescription: A.userDescription.slice(-3) },
    selectedBodyRegion: r.selectedBodyRegion ?? null,
    investigation: {
      cycles: inv.cycles,
      checks: inv.checks.map(({ kind, purpose, prompt, response, status }) => ({ kind, purpose, prompt, response, status })),
      possibleContributingPatterns: inv.patterns.map(({ id, label, status }) => ({ id, label, status })),
      recentEvidence: inv.evidence.slice(-6).map((e) => e.summary),
    },
    completedMovementChecks: r.completedMovementChecks,
    relevantBodyMemory: r.relevantBodyMemory,
  });
}
