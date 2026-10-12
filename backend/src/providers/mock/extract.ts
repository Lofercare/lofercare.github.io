// What one input SAYS, as structured data: the mock provider's "understanding".
// Deterministic keyword rules, deliberately close to the app's on-device SymptomParser so
// the two agree. A real LLM provider replaces this whole file.
import type { ExtractedInformation, AssessmentPatch, WarningSign, MovementResult } from '../../schemas/care.ts';

type Entry = { regionId?: string; template?: string; noun?: string };
const O = '(?:my |the |your )?(?:left |right )?';

/** Body-area phrases → atlas ids or side templates ("{s}" = r/l). First match wins. */
export const PARTS: Array<[string, Entry]> = [
  [`front of ${O}neck|throat`, { regionId: 'neck_f' }],
  [`side of ${O}neck`, { template: '{s}_neckside', noun: 'neck' }],
  [`back of ${O}neck|\\bneck\\b`, { regionId: 'neck_b' }],
  ['rotator cuff', { template: '{s}_sh_back', noun: 'shoulder' }],
  ['between (my |the )?shoulder ?blades|rhomboid|mid(dle)? back', { regionId: 'mid_back' }],
  ['shoulder ?blade|scapula', { template: '{s}_scap', noun: 'shoulder blade' }],
  ['\\btraps?\\b|trapezius', { regionId: 'upperback', template: '{s}_trap' }],
  ['upper back|thoracic', { regionId: 'upperback' }],
  ['lower back|lumbar|\\bmy back\\b|\\bback pain|\\bback (is|feels|has|hurts)', { regionId: 'lowerback', template: '{s}_lowback' }],
  [`front of ${O}shoulder|front delt`, { template: '{s}_sh_front', noun: 'shoulder' }],
  [`back of ${O}shoulder|rear delt`, { template: '{s}_sh_back', noun: 'shoulder' }],
  [`top of ${O}shoulder`, { template: '{s}_sh_top', noun: 'shoulder' }],
  [`outside of ${O}shoulder|outer shoulder|side delt`, { template: '{s}_sh_outer', noun: 'shoulder' }],
  ['shoulder|\\bdelts?\\b|deltoid', { template: '{s}_shoulder', noun: 'shoulder' }],
  ['tennis elbow|outer elbow', { template: '{s}_el_outer', noun: 'elbow' }],
  ['elbow', { template: '{s}_elbow', noun: 'elbow' }],
  ['forearm', { template: '{s}_farm', noun: 'forearm' }],
  ['wrist|carpal', { template: '{s}_wrist', noun: 'wrist' }],
  ['glute|\\bbum\\b|buttock|piriformis', { regionId: 'hips', template: '{s}_glute' }],
  ['\\bhips?\\b', { regionId: 'hips', template: '{s}_hip' }],
  ['hamstring|back of (my )?(left |right )?thigh', { template: '{s}_th_back', noun: 'hamstring' }],
  ['\\bquads?\\b|quadricep', { template: '{s}_th_front', noun: 'quad' }],
  ['thigh', { template: '{s}_thigh', noun: 'thigh' }],
  [`back of ${O}knee|behind ${O}knee`, { template: '{s}_kn_back', noun: 'knee' }],
  ['\\bknees?\\b', { template: '{s}_knee', noun: 'knee' }],
  ['\\bcalf\\b|calves', { template: '{s}_calf', noun: 'calf' }],
  ['achilles', { template: '{s}_achilles', noun: 'achilles' }],
  ['ankle', { template: '{s}_ankle', noun: 'ankle' }],
  ['\\bfoot\\b|\\bfeet\\b', { template: '{s}_footg', noun: 'foot' }],
];
const TYPES: Array<[string, string]> = [
  ['tightness', 'tight|stiff|tense|tension|knot'], ['cramp', 'cramp|spasm'], ['sharp', 'sharp|stabbing|shooting|pinch'],
  ['soreness', '\\bsore|destroyed|wrecked|doms'], ['ache', '\\bach(e|es|y|ing)\\b|dull|nagging|throb'], ['burning', 'burn'],
  ['unclear', 'weird|funny|strange|\\boff\\b|not right|odd'], ['pain', 'pain|hurt|uncomfortable'],
];
const ACTIVITIES: Array<[string, string]> = [
  ['tennis|padel|squash|badminton', 'tennis'], ['\\brun\\b|running|\\bran\\b|\\bjog', 'running'], ['lifting|deadlift|squat|weights', 'lifting'],
  ['\\bgym\\b|workout|training', 'training'], ['sitting|desk|laptop|computer', 'sitting'], ['working|at work|long day', 'work'],
  ['slept|sleeping', 'sleeping'], ['cycling|\\bbike\\b', 'cycling'], ['golf', 'golf'], ['football|soccer|basketball|rugby', 'team sport'],
];
export const TRIGGERS: Array<[string, string]> = [
  ['(above|over) my head|overhead|reach(ing)? up', 'Raising the arm overhead'], ['(lift|raise|raising|lifting) (my |the )?arm(?! (above|over))', 'Lifting the arm'],
  ['reach(ing)? (back|behind|backwards)|behind my back', 'Reaching backwards'], ['rotat(e|ing)|twist(ing)?', 'Rotating'],
  ['turn(ing)? my head|look(ing)? over my shoulder', 'Turning the head'], ['bend(ing)? (over|down|forward)|bending', 'Bending forward'],
  ['when i sit|sitting for|after sitting', 'Prolonged sitting'], ['walking|when i walk', 'Walking'], ['stairs', 'Stairs'],
  ['grip|gripping', 'Gripping'], ['squat|kneel', 'Squatting or kneeling'], ['serv(e|ing)|throw', 'Overhead throwing or serving'],
];
/** Warning signs: urgent = urgent help now; stop = see a professional first; caution = be conservative. */
export const FLAGS: Array<[WarningSign['level'], string, string]> = [
  ['urgent', 'chest pain|pain in (my )?chest|short(ness)? of breath|can\'?t breathe|fainted|passed out|slurred', 'Chest symptoms or breathing difficulty'],
  ['urgent', 'worst headache|sudden severe headache|thunderclap', 'Sudden severe headache'],
  ['urgent', '(lost|losing|loss of) (control of )?(my )?(bladder|bowel)', 'Bladder, bowel or saddle numbness'],
  ['stop', 'numb|tingl|pins and needles|electric shock', 'Numbness or tingling'],
  ['stop', '\\bweak(ness)?\\b|gives way|giving way|can\'?t (move|lift|bear weight|walk|straighten|bend|grip)', 'Weakness or loss of movement'],
  ['stop', 'swollen|swelling|bruis|deform|out of place|dislocat', 'Swelling, bruising or deformity'],
  ['stop', 'popped|\\bsnap|heard a (pop|crack|click)|\\bfell\\b|\\bfall\\b|crash|accident|got hit|knock(ed)?|twisted', 'Recent fall, knock or injury'],
  ['stop', 'fever|night sweats|unexplained weight|wakes me (up )?at night|night pain', 'Fever, night pain or unexplained weight loss'],
  ['stop', '(calf|leg) (is |feels )?(hot|red|swollen|warm)|hot and swollen', 'Hot, red or swollen calf'],
  ['caution', 'sharp|shooting|stabbing', 'Sharp pain'],
  ['caution', 'getting worse|worse (every|each) day|keeps getting worse', 'Getting worse over time'],
];
const NEGATORS = /\b(no|not|never|without|none|nor|neither|haven'?t|hasn'?t|didn'?t|don'?t|doesn'?t|isn'?t|wasn'?t|aren'?t)\b/i;
const UNSURE = /not (really |quite |totally )?sure|unsure|not certain|don'?t know|no idea|can'?t tell|\bmaybe\b|\bmight\b|possibly|perhaps/i;

const has = (t: string, p: string) => new RegExp(p, 'i').test(t);
const normalise = (s: string) => ' ' + s.toLowerCase().replace(/[’‘]/g, "'").replace(/[^a-z0-9/' ]+/g, ' ').replace(/\s+/g, ' ').trim() + ' ';
const clauses = (raw: string) => raw.toLowerCase().replace(/[’]/g, "'").split(/[.,;:!?]+|\b(?:but|and|although|though|however|except)\b/).map(normalise);

/** "no numbness" → negated, "not sure if it's numb" → uncertain, "new numbness" → reported. */
function mention(pattern: string, cl: string[]): WarningSign['status'] | null {
  let result: WarningSign['status'] | null = null;
  for (const c of cl) {
    const m = new RegExp(pattern, 'i').exec(c);
    if (!m) continue;
    const words = c.slice(0, m.index).trim().split(' ').filter(Boolean);
    const near = (n: number) => ' ' + words.slice(-n).join(' ') + ' ';
    const status = UNSURE.test(near(6)) ? 'uncertain' : NEGATORS.test(near(4)) ? 'negated' : 'reported';
    if (status === 'reported') return 'reported';
    if (status === 'uncertain' || result === null) result = status;
  }
  return result;
}

function severity(t: string): number | undefined {
  const m = /\b(10|[0-9])( ?\/ ?10| out of (ten|10))\b/.exec(t);
  if (m) return Number(m[1]);
  if (has(t, 'unbearable|worst|excruciating|agony')) return 9;
  if (has(t, 'terrible|awful|really bad|very bad|a lot\\b')) return 7;
  if (has(t, 'quite a lot|really|quite bad|pretty bad')) return 6;
  if (has(t, 'moderate(ly)?|a fair bit|quite a bit|somewhat')) return 4;
  if (has(t, 'a (little|bit)|slight|mild|niggle|not (much|too bad)')) return has(t, 'not (much|too bad)|a little') ? 2 : 3;
  return undefined;
}
function onset(t: string): AssessmentPatch['onset'] {
  if (has(t, 'just now|this morning|today|an hour ago')) return 'today';
  if (has(t, 'last night')) return 'last night';
  if (has(t, 'yesterday')) return 'yesterday';
  if (has(t, 'few days|couple of days|this week|since (monday|tuesday|wednesday|thursday|friday|saturday|sunday|the weekend)')) return 'a few days ago';
  if (has(t, '(a|one|two|three|couple of|few) weeks?|last week')) return 'weeks ago';
  if (has(t, 'months?|years?|for ages|forever')) return 'months ago';
  return undefined;
}
function movement(t: string): MovementResult | undefined {
  let feel: MovementResult['feel'] | undefined;
  if (has(t, "can'?t|couldn'?t|unable|too (painful|sore)|not comfortably")) feel = 'cannot';
  else if (has(t, 'quite (uncomfortable|sore|painful)|really (hurt|uncomfortable)|a lot')) feel = 'quite';
  else if (has(t, 'halfway|half way|middle|starts (hurting|pulling)|a (little|bit) uncomfortable|bit (sore|tight)|slightly|until i get to')) feel = 'little';
  else if (has(t, '\\b(fine|easy|easier|no problem|comfortable|felt okay|feels okay|looser|better)\\b')) feel = 'fine';
  if (!feel) return undefined;
  return {
    feel,
    whereInMovement: has(t, 'halfway|half way|middle') ? 'about halfway' : has(t, 'the top|the end|all the way|at the end') ? 'near the end of the movement'
      : has(t, 'straight away|as soon as|right at the start') ? 'right from the start' : undefined,
    quality: has(t, 'pull') ? 'pulling' : has(t, 'pinch') ? 'pinching' : has(t, 'tight') ? 'tightness' : undefined,
    sideOfIt: has(t, 'outside|outer') ? 'outside' : has(t, 'inside|inner') ? 'inside' : has(t, 'front') ? 'front' : has(t, '\\bback\\b') ? 'back' : undefined,
  };
}

export interface Extraction { info: ExtractedInformation; patch: AssessmentPatch; text: string }

/** Reads one input. `step` = the app's current care-flow step (a movement description only counts during a movement check). */
export function extract(rawText: string, step?: string | null, expect?: string | null): Extraction {
  const raw = rawText ?? '';
  const t = normalise(raw);
  const cl = clauses(raw);
  const sideText = t.replace(/all right|right now|right away|right after|that'?s right/g, ' ');
  const sideMatch = /\b(right|left)\b/.exec(sideText);
  const entry = PARTS.find(([p]) => has(t, p))?.[1];
  const warningSigns: WarningSign[] = [];
  for (const [level, p, label] of FLAGS) {
    const status = mention(p, cl);
    if (status) warningSigns.push({ level, label, status });
  }
  const sensation = TYPES.find(([, p]) => mention(p, cl) === 'reported')?.[0] as AssessmentPatch['sensation'];
  const triggers = TRIGGERS.filter(([p]) => has(t, p)).map(([, label]) => label);
  const duration = /for (about |around |roughly |over )?(an? |one |two |three |four |half an |\d+ )(hours?|minutes?|mins?)/.exec(t);
  const specific = entry?.template?.match(/_(back|front|outer|inner|top)$/)?.[1] as AssessmentPatch['specificArea'];
  const direction = has(t, '\\b(lower|down|below)\\b') ? 'down' : has(t, '\\b(higher|up|above)\\b') && !has(t, 'above my head') ? 'up'
    : has(t, 'towards the back|more back|further back|to the back') ? 'back' : has(t, 'towards the front|to the front|more front') ? 'front'
    : has(t, '\\b(outside|outer|outwards?)\\b') ? 'out' : has(t, '\\b(inside|inner|inwards?)\\b') ? 'in' : undefined;

  const info: ExtractedInformation = {
    bodyMention: entry ? { regionId: entry.regionId, template: entry.template, noun: entry.noun } : undefined,
    side: sideMatch ? (sideMatch[1] as 'left' | 'right') : undefined,
    bilateral: has(t, '\\b(both|calves|shoulders|knees|hamstrings|legs|arms|hips)\\b') || undefined,
    warningSigns,
    confirm: has(t, "\\b(yes|yep|yeah|yup|correct|exactly|perfect)\\b|that'?s (it|the spot|right)|spot on|right there|sounds good") || undefined,
    deny: has(t, '\\b(no|nope|not quite|not really|wrong)\\b') || undefined,
    unsure: UNSURE.test(t) || undefined,
    skip: has(t, '\\bskip|rather not (say|answer)') || undefined,
    direction: entry ? undefined : direction,
    slight: has(t, 'slight|little|\\bbit\\b') || undefined,
    movementResult: step === 'movement' ? movement(t) : undefined,
    // An answer, in words, to the observation Lofer just asked for ("did it ease when you stopped?").
    observation: expect?.startsWith('observation:') ? observationAnswer(t) : undefined,
  };
  const patch: AssessmentPatch = {
    sensation,
    severity: severity(t),
    onset: onset(t),
    onsetType: has(t, 'suddenly|all of a sudden|out of nowhere|felt a (pop|twinge|ping)') ? 'sudden' : has(t, 'gradually|crept up|built up|over time') ? 'gradual' : undefined,
    activityContext: ACTIVITIES.find(([p]) => has(t, p))?.[1],
    activityDuration: duration ? duration[0].replace(/^for /, '') : undefined,
    symptomsAtRest: has(t, 'all the time|constant(ly)?|even (at rest|when i\'?m still|lying down)|doesn\'?t go away') ? 'present'
      : has(t, '(mostly|generally|usually|otherwise) (okay|ok|fine|alright)|fine (at rest|normally)|only (hurts|bothers me) when|fine until') ? 'minimal' : undefined,
    progression: has(t, 'getting better|improving|easing') ? 'improving' : has(t, 'getting worse|worse (each|every)|worsening') ? 'worsening' : undefined,
    previousEpisodes: has(t, 'again|keeps|every time|recurring|comes back|as usual') || undefined,
    movementTriggers: triggers.length ? triggers : undefined,
    specificArea: specific,
  };
  return { info: strip(info), patch: strip(patch), text: raw.trim() };
}

function observationAnswer(t: string): ExtractedInformation['observation'] {
  if (UNSURE.test(t)) return { label: 'Not sure', value: 'unsure' };
  if (has(t, 'linger|still there|didn\'?t (ease|settle)|not really|\bno\b')) return { label: 'It lingered', value: 'lingered' };
  if (has(t, 'eased|settled|went away|gone|\byes\b|better')) return { label: 'Yes, it eased', value: 'eased' };
  return undefined;
}

/** Drop undefined keys so the JSON is tidy (and validation stays strict). */
function strip<T extends object>(o: T): T {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as T;
}
