// MockCareIntelligenceProvider — stands in for the future LLM, with the SAME interface and
// the SAME validated output. Deterministic rules, not AI: its job is to exercise the real
// architecture end to end (context in, structured understanding + a proposed next step out).
//
// How it thinks, every turn:
//   1. read the latest input (extract.ts) and combine it with everything already known
//   2. list what matters that's still uncertain
//   3. suggest possible contributing patterns (never diagnoses), with supporting/weakening evidence
//   4. propose ONE next step that would reduce the most important uncertainty
//   5. phrase a short acknowledgement + that step in Lofer's voice
// The iOS app's InvestigationEngine and SafetyValidator decide whether the step happens.
import type { CareIntelligenceProvider } from '../CareIntelligenceProvider.ts';
import { SCHEMA_VERSION } from '../../schemas/care.ts';
import type {
  CareRequest, CareIntelligenceResponse, InvestigationAction, ContributingPattern, Uncertainty, Evidence, AssessmentPatch,
} from '../../schemas/care.ts';
import { extract } from './extract.ts';

// Movement checks the app has content for (ids match Lofer/Models/MovementTest.swift).
export const MOVEMENTS: Array<{ id: string; matches: RegExp; name: string; prompt: string; release: string }> = [
  { id: 'arm_raise', matches: /_sh_|shoulder|_ua_|uarm|_trap|_scap|chest|_lat/, name: 'arm raise', prompt: "Let's see how lifting your arm feels.", release: 'lowered your arm' },
  { id: 'head_turn', matches: /neck|backhead|headneck/, name: 'head turn', prompt: "Let's see how turning your head feels.", release: 'came back to the middle' },
  { id: 'forward_reach', matches: /lowerback|lowback|_glute|_hip|hips|mid_back|upperback/, name: 'forward reach', prompt: "Let's see how a gentle reach forward feels.", release: 'rolled back up' },
  { id: 'heel_raise', matches: /calf|achilles|ankle|heel|sole|foot|lleg|shin/, name: 'heel raise', prompt: "Let's see how rising onto your toes feels.", release: 'lowered your heels' },
  { id: 'mini_squat', matches: /knee|_kn_|thigh|_th_/, name: 'mini squat', prompt: "Let's see how a small knee bend feels.", release: 'stood back up' },
  { id: 'wrist_lift', matches: /elbow|_el_|farm|wrist|_wr_|hand|palm|thumb|fingers/, name: 'wrist lift', prompt: "Let's see how lifting your hand feels.", release: 'lowered your hand' },
];
const SPORTS = /tennis|running|lifting|training|cycling|golf|team sport|climbing/;
const OBSERVATION_ID = 'eases_when_stopped';

/** Everything known so far, with this input folded in (the mock's working view, not the app's record). */
interface View {
  region?: string; noun: string; side?: string; lateral: boolean; specificArea?: string; confirmed: boolean;
  sensation?: string; severity?: number; onset?: string; activity?: string; duration?: string; atRest?: string;
  progression?: string; triggers: string[]; seriousSigns: { label: string; urgent: boolean }[]; uncertainSigns: string[];
  safetyAnswer?: string; baseline?: CareRequest['completedMovementChecks'][number]; skippedMovement: boolean;
  observationDone: boolean; observationValue?: string; movement?: (typeof MOVEMENTS)[number]; questions: number; cycles: number;
}

export class MockCareIntelligenceProvider implements CareIntelligenceProvider {
  readonly name = 'mock';

  async respond(request: CareRequest): Promise<CareIntelligenceResponse> {
    const input = request.latestUserInput;
    const { info, patch } = extract(input.kind === 'utterance' ? input.text ?? '' : '', request.currentCareFlowState, request.expectedField);
    const v = this.view(request, info, patch);
    const evidence = this.evidence(request, input, patch);
    const patterns = this.patterns(v);
    const uncertainties = this.uncertainties(v);
    const action = this.nextAction(v, uncertainties);
    return {
      schemaVersion: SCHEMA_VERSION,
      requestId: request.requestId,
      provider: this.name,
      extractedInformation: info,
      assessmentUpdates: patch,
      possibleContributingPatterns: patterns,
      uncertainties,
      evidenceUpdates: evidence,
      recommendedNextAction: action,
      readiness: this.readiness(v, action),
      userFacingResponse: { acknowledgement: this.acknowledge(request, input, patch, v), prompt: this.prompt(action) },
    };
  }

  // ── 1. Combine what was just said with what's already known ──────────────
  private view(r: CareRequest, info: ReturnType<typeof extract>['info'], p: AssessmentPatch): View {
    const A = r.currentAssessmentState;
    const sideWord = info.side ?? (A.laterality === 'left' || A.laterality === 'right' ? A.laterality : undefined);
    const template = info.bodyMention?.template;
    const region = template && sideWord ? template.replace('{s}', sideWord[0]) : info.bodyMention?.regionId ?? A.bodyRegion ?? undefined;
    const area = region ?? template ?? '';
    const known = (field: string) => A.answers[field] !== undefined;
    const observation = r.investigation.checks.find((c) => c.kind === 'observation' && c.purpose === OBSERVATION_ID);
    const latestObservation = r.latestUserInput.kind === 'observation' && r.latestUserInput.field === OBSERVATION_ID ? r.latestUserInput.value ?? undefined
      : r.expectedField === `observation:${OBSERVATION_ID}` ? info.observation?.value : undefined;
    const signs = [...A.safetyFlags, ...info.warningSigns.filter((w) => w.status === 'reported')];
    return {
      region, noun: info.bodyMention?.noun ?? nounOf(area), side: sideWord, lateral: !!template || /^[rl]_/.test(area),
      specificArea: p.specificArea ?? A.specificArea ?? undefined, confirmed: A.regionConfirmed,
      sensation: A.sensation && !['pain', 'unclear'].includes(A.sensation) ? A.sensation : p.sensation ?? A.sensation ?? undefined,
      severity: p.severity ?? A.severity ?? undefined, onset: p.onset ?? A.onset ?? undefined, activity: p.activityContext ?? A.activityContext ?? undefined,
      duration: p.activityDuration ?? A.activityDuration ?? undefined, atRest: p.symptomsAtRest ?? A.symptomsAtRest ?? undefined,
      progression: p.progression ?? A.progression ?? undefined, triggers: [...new Set([...A.movementTriggers, ...(p.movementTriggers ?? [])])],
      seriousSigns: signs.filter((s) => s.level !== 'caution').map((s) => ({ label: s.label, urgent: s.level === 'urgent' })),
      uncertainSigns: [...A.uncertainSigns.map((s) => s.label), ...info.warningSigns.filter((w) => w.status === 'uncertain').map((w) => w.label)],
      safetyAnswer: known('safety') ? A.answers.safety : undefined,
      // The baseline: an earlier recorded check, or the one being described in this very input.
      baseline: r.completedMovementChecks.find((m) => m.phase === 'baseline') ?? this.describedBaseline(r, info),
      skippedMovement: r.investigation.checks.some((c) => c.kind === 'movement' && c.status === 'skipped'),
      observationDone: !!observation || !!latestObservation, observationValue: latestObservation ?? observation?.response ?? undefined,
      movement: MOVEMENTS.find((m) => m.matches.test(area)), questions: r.investigation.checks.filter((c) => c.kind === 'question').length,
      cycles: r.investigation.cycles,
    };
  }

  /** A movement result said in words during the movement check, before the app has recorded it. */
  private describedBaseline(r: CareRequest, info: ReturnType<typeof extract>['info']): View['baseline'] {
    const m = info.movementResult;
    const movement = MOVEMENTS.find((x) => x.matches.test(r.currentAssessmentState.bodyRegion ?? ''));
    if (!m || !movement || r.currentCareFlowState !== 'movement') return undefined;
    const outcome = ({ fine: 'comfortable', little: 'mildDiscomfort', quite: 'significantDiscomfort', cannot: 'unableToPerformComfortably' } as const)[m.feel];
    return { movementId: movement.id, name: movement.name, phase: 'baseline', outcome, whereInMovement: m.whereInMovement ?? undefined,
             quality: m.quality ?? undefined, at: new Date().toISOString() };
  }

  // ── 2. What matters that we don't know ──────────────────────────────────
  private needsSafetyCheck(v: View): boolean {
    if (v.safetyAnswer || v.seriousSigns.length) return false;
    return v.uncertainSigns.length > 0 || ['sharp', 'burning'].includes(v.sensation ?? '') || (v.severity ?? 0) >= 7
      || v.atRest === 'present' || v.onset === 'months ago' || v.progression === 'worsening';
  }
  private uncertainties(v: View): Uncertainty[] {
    const u: Uncertainty[] = [];
    if (!v.region && !v.noun) u.push({ id: 'where', topic: 'Where it is felt', importance: 'high', field: 'region' });
    else if (v.lateral && !v.side) u.push({ id: 'side', topic: 'Which side', importance: 'high', field: null });
    else if (!v.confirmed) u.push({ id: 'precise-area', topic: v.specificArea ? 'The exact spot' : `Which part of the ${v.noun}`, importance: 'medium', field: null });
    if (!v.sensation || ['pain', 'unclear'].includes(v.sensation)) u.push({ id: 'feeling', topic: 'What it feels like', importance: 'high', field: 'sensation' });
    if (this.needsSafetyCheck(v)) u.push({ id: 'warning-signs', topic: 'Numbness, tingling, swelling or weakness', importance: 'high', field: 'safety' });
    if (v.movement && !v.baseline && !v.skippedMovement) u.push({ id: 'movement-response', topic: `How the ${v.movement.name} feels`, importance: 'high', field: null });
    if (v.baseline && v.baseline.outcome === 'mildDiscomfort' && !v.observationDone) u.push({ id: 'settles', topic: 'Whether it settles when the movement stops', importance: 'medium', field: null });
    if (!v.triggers.length && !v.atRest) u.push({ id: 'triggers', topic: 'What brings it on', importance: 'low', field: 'triggers' });
    if (!v.onset && !v.activity) u.push({ id: 'onset', topic: 'When it started', importance: 'low', field: 'onset' });
    return u;
  }

  // ── 3. Possible contributing patterns (never a diagnosis) ───────────────
  private patterns(v: View): ContributingPattern[] {
    const out: ContributingPattern[] = [];
    const add = (id: string, label: string, supporting: string[], weakening: string[]) => {
      if (!supporting.length) return;
      const status = weakening.length > supporting.length ? 'weakened' : supporting.length >= 2 && !weakening.length ? 'supported' : 'possible';
      out.push({ id, label, status, supporting, weakening });
    };
    const eased = v.observationValue === 'eased' || /eased/i.test(v.observationValue ?? '');
    const lingered = v.observationValue === 'lingered' || /linger/i.test(v.observationValue ?? '');
    add('activity-load', 'Tightness building up after a demanding activity',
      [v.activity && SPORTS.test(v.activity) ? `after ${v.activity}` : '', v.duration ? `${v.duration} of activity` : '',
       ['tightness', 'soreness'].includes(v.sensation ?? '') ? `feels ${v.sensation}` : ''].filter(Boolean),
      [v.atRest === 'present' ? 'there even at rest' : '', v.progression === 'worsening' ? 'getting worse' : ''].filter(Boolean));
    add('movement-provoked', 'Discomfort that shows up with a particular movement',
      [v.triggers.length ? `noticed when ${v.triggers[0].toLowerCase()}` : '', v.baseline && v.baseline.outcome !== 'comfortable' ? `${v.baseline.name} ${v.baseline.outcome === 'mildDiscomfort' ? 'a little uncomfortable' : 'uncomfortable'}` : '',
       eased ? 'eased when the movement stopped' : '', v.atRest === 'minimal' ? 'mostly fine at rest' : ''].filter(Boolean),
      [v.baseline?.outcome === 'comfortable' ? 'movement check felt fine' : '', lingered ? 'lingered after the movement' : ''].filter(Boolean));
    add('sustained-position', 'Stiffness linked to a sustained position',
      [v.activity && /sitting|work|sleeping/.test(v.activity) ? `after ${v.activity}` : '', v.triggers.includes('Prolonged sitting') ? 'worse after sitting' : ''].filter(Boolean), []);
    add('persistent', 'Ongoing discomfort that isn’t only movement-related',
      [v.atRest === 'present' ? 'there even at rest' : '', v.onset === 'months ago' ? 'has lasted months' : '', v.progression === 'worsening' ? 'getting worse' : ''].filter(Boolean),
      [v.atRest === 'minimal' ? 'mostly fine at rest' : ''].filter(Boolean));
    return out;
  }

  // ── 4. Propose ONE next step ────────────────────────────────────────────
  private nextAction(v: View, u: Uncertainty[]): InvestigationAction {
    if (v.seriousSigns.length) {
      return { type: 'safetyStop', reason: v.seriousSigns.map((s) => s.label).join('; '), urgent: v.seriousSigns.some((s) => s.urgent) };
    }
    if (v.atRest === 'present' && (v.onset === 'months ago' || v.progression === 'worsening')) {
      return { type: 'recommendProfessionalAssessment', reason: 'Ongoing, present at rest, and lasting or worsening',
               message: "This has been there a while, even at rest. It's worth having it looked at by a GP or physiotherapist rather than starting a session." };
    }
    if (v.cycles >= 6 || (!v.region && !v.noun && v.cycles >= 2)) {
      return { type: 'insufficientInformation', reason: 'Area or feeling still unclear after several steps',
               message: "I don't have enough information to recommend a session here." };
    }
    if (!v.region && !v.noun) {
      return { type: 'refineBodyLocation', broadRegion: 'body', requestedRefinement: 'region',
               prompt: 'Where do you notice it most? Tap the body, or tell me.', purpose: 'Find the area' };
    }
    if (v.lateral && !v.side) {
      return { type: 'refineBodyLocation', broadRegion: v.noun, requestedRefinement: 'side', prompt: `Which ${v.noun} is it, left or right?`, purpose: 'Find the side' };
    }
    if (this.needsSafetyCheck(v)) {
      return { type: 'askQuestion', field: 'safety', question: 'One quick check. Is there any numbness, tingling, swelling or weakness with it?',
               purpose: 'Rule out warning signs before any care', multiSelect: true };
    }
    if (u.some((x) => x.id === 'feeling') && v.questions < 3) {
      return { type: 'askQuestion', field: 'sensation', question: 'What does it feel like? More tight, sore, achy or sharp?', purpose: 'Understand the kind of discomfort' };
    }
    if (!v.confirmed) {
      return { type: 'refineBodyLocation', broadRegion: v.noun, currentSelection: v.region ?? null,
               requestedRefinement: v.specificArea ? 'precise' : 'surface',
               prompt: "Show me where it's most noticeable.", purpose: 'Pin down the area care would be applied to' };
    }
    if (v.movement && !v.baseline && !v.skippedMovement) {
      return { type: 'movementCheck', movementId: v.movement.id, phase: 'baseline', purpose: 'See how the area responds to movement',
               targetObservation: 'Where in the movement it becomes noticeable, and where it is felt' };
    }
    if (v.baseline?.outcome === 'mildDiscomfort' && !v.observationDone && v.movement) {
      const where = v.baseline.whereInMovement ? ` ${v.baseline.whereInMovement}` : '';
      return { type: 'requestUserObservation', observationId: OBSERVATION_ID,
               prompt: `You felt it${where}. Did it ease when you ${v.movement.release}?`, purpose: 'Whether it settles when the movement stops',
               options: [{ label: 'Yes, it eased', value: 'eased' }, { label: 'It lingered', value: 'lingered' }, { label: 'Not sure', value: 'unsure' }] };
    }
    if (v.baseline?.outcome === 'unableToPerformComfortably' && v.sensation === 'sharp') {
      return { type: 'recommendProfessionalAssessment', reason: 'A simple movement could not be done comfortably, with sharp pain',
               message: "That movement wasn't comfortable, and it feels sharp. It's worth having it looked at before starting a session." };
    }
    const reasons = [v.baseline ? `${v.baseline.name} observed` : 'no movement check for this area', v.observationDone ? 'response to stopping noted' : ''].filter(Boolean);
    return { type: 'proceedToCare', reason: `Enough to consider conservative care: area confirmed, feeling known, ${reasons.join(', ')}.` };
  }

  private readiness(v: View, action: InvestigationAction): CareIntelligenceResponse['readiness'] {
    if (action.type === 'proceedToCare') return { informationSufficiency: 'sufficient', reason: action.reason };
    if (v.region && v.sensation) return { informationSufficiency: 'partial', reason: 'The area and feeling are known; one more check would help.' };
    return { informationSufficiency: 'insufficient', reason: 'The area or the feeling is still unclear.' };
  }

  // ── Evidence from this input (the user is a sensor) ─────────────────────
  private evidence(r: CareRequest, input: CareRequest['latestUserInput'], p: AssessmentPatch): Evidence[] {
    const at = new Date().toISOString();
    const e: Evidence[] = [];
    const id = () => `mock-${r.turn}-${e.length + 1}`;
    if (p.activityContext && p.activityDuration) e.push({ id: id(), source: 'careIntelligence', summary: `Started after ${p.activityDuration} of ${p.activityContext}`, field: 'activityContext', value: p.activityContext, supports: ['activity-load'], weakens: [], at });
    if (p.symptomsAtRest === 'minimal') e.push({ id: id(), source: 'careIntelligence', summary: 'Mostly fine at rest', field: 'symptomsAtRest', value: 'minimal', supports: ['movement-provoked'], weakens: ['persistent'], at });
    if (input.kind === 'observation' && input.field === OBSERVATION_ID) {
      const eased = input.value === 'eased';
      e.push({ id: id(), source: 'careIntelligence', summary: eased ? 'Settles when the movement stops' : 'Did not clearly settle when the movement stopped',
               field: OBSERVATION_ID, value: input.value ?? undefined, supports: eased ? ['movement-provoked'] : [], weakens: eased ? [] : ['movement-provoked'], at });
    }
    return e;
  }

  // ── 5. Lofer's voice: short acknowledgement, one next step ──────────────
  private acknowledge(r: CareRequest, input: CareRequest['latestUserInput'], p: AssessmentPatch, v: View): string {
    if (input.kind === 'location') return "Thanks, that's the spot.";
    if (input.kind === 'observation') return input.value === 'eased' ? 'Good, it settled when you stopped.' : input.value === 'lingered' ? "Thanks, I've noted it lingered." : "That's fine.";
    if (input.kind !== 'utterance') return 'Thanks.';
    const bits: string[] = [];
    if (p.activityContext) bits.push(`it started after ${p.activityContext}${p.onset ? ` ${p.onset}` : ''}`);
    if (v.region || v.noun) {
      const where = v.specificArea && v.noun ? `the ${v.specificArea} of your ${v.side ? v.side + ' ' : ''}${v.noun}` : `your ${v.side ? v.side + ' ' : ''}${v.noun}`;
      if (r.turn <= 1 || r.currentAssessmentState.bodyRegion == null) bits.push(`you're feeling it around ${where}`);
    }
    if (!bits.length) return p.sensation || p.movementTriggers ? 'Got it.' : '';
    return `Got it — ${bits.join(', and ')}.`;
  }
  private prompt(a: InvestigationAction): string {
    switch (a.type) {
      case 'askQuestion': return a.question;
      case 'refineBodyLocation': return a.prompt;
      case 'movementCheck': return MOVEMENTS.find((m) => m.id === a.movementId)?.prompt ?? "Let's see how a simple movement feels.";
      case 'requestUserObservation': return a.prompt;
      case 'proceedToCare': return "Here's what we checked.";
      case 'insufficientInformation': case 'recommendProfessionalAssessment': return a.message;
      case 'safetyStop': return "Let's stop here.";
    }
  }
}

/** "shoulder", "lower back"… from an atlas id or template. */
function nounOf(area: string): string {
  const table: Array<[RegExp, string]> = [[/_sh_|shoulder/, 'shoulder'], [/lowback|lowerback/, 'lower back'], [/neck/, 'neck'], [/knee|_kn_/, 'knee'],
    [/calf/, 'calf'], [/elbow|_el_/, 'elbow'], [/wrist|_wr_/, 'wrist'], [/hip|glute/, 'hip'], [/th_|thigh|hamstring/, 'thigh'], [/upperback|trap/, 'upper back']];
  return table.find(([re]) => re.test(area))?.[1] ?? '';
}
