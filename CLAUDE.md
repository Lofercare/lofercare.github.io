# Working on Lofer (notes for Claude)

- **This repository is the canonical Lofer codebase.** The hosted web Artifact is a historical reference only (`docs/artifact-reference/`). Do not build features there.
- Workflow for any change: inspect the existing code → edit the relevant files → build (`xcodebuild … build`) and test (`xcodebuild … test`) → list exactly which files changed → commit on a feature branch when asked → push / open a PR only when asked.
- The owner is learning software engineering: keep names obvious, add short comments where a design choice isn't self-evident, prefer small focused edits, and explain changes file by file.
- Keep the layers separate: Views → `CareFlowModel` → Services (`AssessmentService`, `TreatmentEngine`, `SafetyValidator`) → `DeviceInterface`. Voice never controls hardware; only `SafetyValidator` can create `SealedCommand`s. `AppModel` and `CareFlowModel` depend only on the `VoiceAgent` protocol (never `MockVoiceAgent`); the provider is chosen in `AppModel.init(voice:)`.
- Never commit secrets or API keys. Real providers get tokens from a backend.
- Build: `xcodebuild -project Lofer.xcodeproj -scheme Lofer -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: same command with `test`.
- Demo for screenshots: launch with `-LoferDemoFull`.
- The body mesh is generated from `docs/artifact-reference/geo.js`: `node tools/generate-body-mesh.js`.
- **Website** lives in `website/` (Vite + three.js, plain JS). Run `npm run dev` / `npm run build` inside `website/`. The product/logo outline (six identical petals, 20 numbers) lives in `website/src/deviceShape.js` and `Lofer/Components/LoferMark.swift`: keep the two in sync. The app icon (light + dark) is in `Assets.xcassets/AppIcon.appiconset`; colours mirror `Lofer/DesignSystem/Colors.swift`.
- **Backend** lives in `backend/` (Node 24 TypeScript, no build step): `npm start`, `npm test`, `npm run typecheck`. `POST /api/care` takes a `CareRequest` and returns a `CareIntelligenceResponse` (schemas mirrored in `backend/src/schemas/care.ts` and `Lofer/Services/Intelligence/CareSchema.swift`: change both together). Providers: `mock` (tests) and `openai` (approved by the owner; key only in the git-ignored `backend/.env`). Never print, log or commit the key; don't add other providers without the owner's approval.
- **Voice** (Phase 4, `docs/PHASE-4-VOICE.md`): ElevenLabs is used ONLY for speech-to-text (Scribe v2 Realtime) and text-to-speech, never as an agent/LLM. The backend holds `ELEVENLABS_API_KEY`; the app gets single-use tokens and streamed audio from `/api/voice/*`, authenticated with `LOFER_CLIENT_KEY` (local scheme "Lofer (Real Voice)", git-ignored). `-LoferVoice mock|elevenlabs` picks the provider (default mock). Voice only ever stops audio; actions go through the care flow.
- Care Intelligence only proposes; `InvestigationEngine` (deterministic) and `SafetyValidator` decide. The end-to-end test `EndToEndBackendTests` runs only when the backend is up.
