# Phase 4: real voice (ElevenLabs speech-to-text + text-to-speech)

ElevenLabs is used **only** as Lofer's ears and mouth. There is no ElevenLabs agent, agent LLM,
custom LLM or agent tool. Lofer's own Care Intelligence, InvestigationEngine, TreatmentEngine and
SafetyValidator run the conversation and make every decision, exactly as they do for typed input.

## Flow

```
USER SPEAKS
  → ScribeRealtimeRecognizer   mic (16 kHz PCM, echo-cancelled) → wss Scribe v2 Realtime (single-use token)
  → partial transcripts        shown as "heard" only
  → committed transcript       ONE final per utterance → VoiceAgent.onTranscript(text, true)
  → AppModel.transcript        the same entry point typed text uses
  → CareFlowModel.hear         Care Intelligence → InvestigationEngine → step (body map, movement check, sheets)
  → say(line)                  the line on screen
  → BackendSpeechSynthesizer   POST /api/voice/speech → ElevenLabs Flash → streamed PCM → speaker
```

## Pieces

| Where | What |
|---|---|
| `Lofer/Services/Voice/SpeechServices.swift` | `SpeechRecognitionService` (ears) and `SpeechSynthesisService` (mouth) protocols |
| `ElevenLabsVoiceAgent.swift` | The `VoiceAgent`: hands-free listening, turn-taking, interruption, echo guard, reconnect, errors |
| `ScribeRealtimeRecognizer.swift` | Speech-to-text WebSocket client (+ `AudioChunkSender`) |
| `BackendSpeechSynthesizer.swift` | Text-to-speech: one streamed HTTP request per line, played as it arrives |
| `VoiceAudioEngine.swift` | Audio session, microphone capture, playback, echo cancellation, route changes |
| `VoiceBackendClient.swift` | `/api/voice/token` and `/api/voice/speech` |
| `VoiceInterrupts.swift` | Urgent phrases ("stop", "pause", "that hurts"), echo and barge-in checks |
| `VoiceConfig.swift` | `-LoferVoice mock\|elevenlabs` (default mock), `-LoferVoiceBargeIn off` |
| `backend/src/voice/` | `VoiceProvider` interface, ElevenLabs provider, mock provider |
| `backend/src/routes/voice.ts` | The two voice routes |
| `backend/src/security/` | Client key check and rate limits (also applied to `/api/care`) |

`CareFlowModel`, `InvestigationEngine`, `TreatmentEngine`, `SafetyValidator` and
`CareIntelligenceService` are unchanged.

## Rules

- **Only final transcripts** reach the care flow, each once and in order. Speech heard while the
  previous utterance is still being handled is queued, not dropped (and not sent twice).
- **What is spoken** is exactly what `CareFlowModel.say()` passes to the voice agent: the line on
  screen. That line is the Care Intelligence wording *only* when the InvestigationEngine accepted its
  proposal and `CareLanguage` approved the words; otherwise it's Lofer's deterministic wording.
  (One case speaks a little more than it shows: the reassessment result adds the reason, which is
  on the result sheet.)
- **"Stop", "pause" or discomfort** heard while Lofer talks cuts the audio on the *partial*
  transcript and finishes the utterance early. The final transcript then goes to the care flow at
  once (no 600 ms pause), which decides what happens through its normal safety logic. The voice
  layer only ever stops audio.
- **Echo guard**: Lofer's own voice coming back through the mic is ignored, so its safety question
  ("any numbness, tingling…") can't be heard as the user reporting warning signs. A single urgent
  word is never treated as echo: if in doubt, stop.
- **Barge-in** (on by default): two or more words of real speech cut Lofer off.
- **Hands-free**: listening continues after Lofer answers until the mic is tapped, the user switches
  to typing, or nothing is heard for 2 minutes (privacy, and transcription is billed while open).
- **Errors**: microphone denied, backend refused or unreachable → the label says so and typing
  still works. A dropped transcription connection reconnects once with a fresh token. A phone call
  stops listening and resumes it afterwards. A failed spoken line is still on screen.

## Credentials

- `backend/.env` (git-ignored): `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `VOICE_PROVIDER=elevenlabs`,
  `LOFER_CLIENT_KEY`. The ElevenLabs key never leaves the backend; the app gets a single-use
  speech-to-text token (15 minutes, one connection) and streamed audio.
- The app sends `Authorization: Bearer <LOFER_CLIENT_KEY>`, read from `LOFER_CLIENT_KEY` in the
  **local** scheme "Lofer (Real Voice)" (in `xcuserdata/`, git-ignored).
- The shared client key is fine for development and TestFlight, but it can be extracted from an app
  binary. **Before a public release, replace it with Apple App Attest** (backend verifies a
  per-device attestation before issuing tokens or speech).
- Rate limits: care 30/min, voice tokens 6/min, speech 40/min per address; 50,000 speech
  characters per day for the whole server (all configurable in `.env`).

## Running it

1. `cd backend && npm start` (it should say `voice: elevenlabs · client key required`).
2. In Xcode choose the **Lofer (Real Voice)** scheme and run on the simulator (it uses the Mac's
   microphone) or a phone (set `HOST=0.0.0.0` and `-LoferBackendURL http://<your-mac>.local:8787`).
3. Tap the orb and talk. The **Lofer** scheme stays on the mock voice.

## Costs and latency (measured / list prices, October 2026)

- Speech-to-text: Scribe v2 Realtime ≈ $0.39 per hour the microphone is open.
- Text-to-speech: Flash ≈ $0.04 per 1,000 characters; a care session is ≈ 2,000 characters.
- Measured: first audio ≈ 265 ms after a speech request (backend on the same Mac).
- A turn is dominated by Care Intelligence (OpenAI, 1.5–4 s); add ≈ 0.8 s of silence before Scribe
  commits, and the app's 600 ms correction window (skipped for urgent phrases).

## Known limitations

- **ElevenLabs free plan:** library voices are refused over the API (402 `paid_plan_required`);
  built-in ("premade") voices work. Lofer uses the built-in voice "George" (`JBFqnCBsd6RMkjVDRZzb`).
  If speech ever fails, the line is still shown on screen.
- Echo cancellation depends on iOS voice processing; on some simulator setups it's unavailable and
  the text-based echo guard does all the work.
- English only (`language_code=en`).
- ElevenLabs request logging is on by default for these APIs; zero-retention mode needs an
  enterprise plan. The backend never logs transcript or speech text.
