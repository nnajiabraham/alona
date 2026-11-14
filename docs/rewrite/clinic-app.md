# The clinic app: a white-label patient-note build of Alona

The clinic app records a consultation and transcribes it on the device. A local model then drafts a clinical note in the tenant's template. The clinician edits the draft, marks it as reviewed, and then copies or shares it. The app is one Exact app in `clinic/`. It shares Alona's `core/` pipeline and engines. A tenant (one branded build) is one typed file in `tenants/` plus an icon. `tenants/README.md` is the guide for tenant authors.

## Data shapes

### The note format is a profile (core/notes.ts)

```ts
interface NoteSection { heading: string; guidance: string }
interface NotesProfile {
  recording: string;            // "meeting", "consultation": used in prompts
  system: string;               // the one-shot system prompt
  extractSystem: string;        // the map step's system prompt (long recordings)
  intro: string; titleRule: string; sections: NoteSection[]; closing: string;
  missingSection: string;       // written under a heading the model left out
  extractHeadings: string;
  emptyResult: string;          // the note for a recording with no speech
  ownNotesLabel: string;        // how the person's jottings are introduced
}
```

- `ALONA_NOTES` is Alona's format as a profile.
- `stepRequest(profile, …)` and `finishNotes(profile, raw)` take the profile.
- `service(engine, store, demo, { profileOf })` picks a profile per recording. It defaults to `ALONA_NOTES`.
- A golden test proves that Alona's output did not change. It covers every request and every finished note for a short case, a 150-line map-reduce case, a silent case, and six raw model replies. The golden values were generated from `core/notes.ts` at commit `a378354`, before the change. A deliberate one-character change to the prompt fails the test.

### A tenant (tenants/schema.ts)

```ts
interface TenantConfig<TemplateId extends string> {
  slug: TenantSlug;                                   // branded; equals the file name
  app: { name; shortName; tagline; bundleId: BundleId; version };
  colors: Record<ColorToken, { light: Hex; dark: Hex }>;   // 13 tokens
  copy: { welcomeTitle; welcomeBody; person: { singular; plural }; reviewDisclaimer; privacy };
  templates: NonEmpty<NoteTemplate<TemplateId>>;      // { id, name, description, sections: NonEmpty<{ heading, guidance }> }
  defaults: { template: NoInfer<TemplateId>; tier: 'auto' | 'lite' | 'balanced' | 'quality' };
  features: { jottings; copy; share; playback };
  support?: { email?; url?; hours? };
  icon: string;
}
```

`defineTenant` infers the template ids, so a default template that no template has is a type error. `tenants/validate.ts` returns `{ field, message }[]` for the rules that types cannot express: WCAG contrast in both schemes, formats, uniqueness, the icon file, word length in the welcome title, and compliance claims in the privacy text. Each message names the field and the fix. There are 17 tests, one failing config per rule.

### A clinic note on disk

A clinic note uses Alona's meeting folder, `app:/data/meetings/<id>/`, plus three files that the person's actions write. The pipeline never writes those three files.

| File | Writer | Holds |
|---|---|---|
| `meeting.json`, `notes.md` (jottings) | person | as in Alona |
| `stage.json`, `transcript.json`, `ai-notes.md` (the draft) | pipeline | as in Alona |
| `clinic.json` | person | `{ patientRef, templateId }` |
| `edited.md` | person | the clinician's edits; empty means no edits |
| `review.json` | person | `{ at, text }`: when the note was reviewed, and what it said then |

The note's state is derived and never stored:
- `processing` or `failed` come from the pipeline stage.
- Otherwise the state is `reviewed` when `review.text` equals the note shown (the edits if any, else the draft), and `draft` if not.

An edit after review therefore returns the note to draft, with no flag to keep in sync. "Write again" and "Transcribe again" clear `edited.md` first, and only after the clinician confirms.

## Screens and flows

| Screen | What it does |
|---|---|
| Welcome | Tenant title, tagline and body; the recommended models; "Download models and continue" or "Not now" |
| Notes (home) | "New note" card, model banner, notes newest first with reference, template, time and a state chip |
| New note (sheet) | Patient reference (the hint says to avoid names, dates of birth and record numbers), template choice, a consent reminder, "Start recording" |
| Recording (modal) | Reference, timer, waveform in the tenant's tint, "Stop and draft the note", jottings. Back, swipe and Escape also stop and save |
| Note | Reference field, meta line, player (if enabled); Note, Transcript and Jottings panes; "AI draft · Not reviewed" with the tenant's disclaimer, or "Reviewed <date>"; Edit (a Markdown editor that saves as you type); Mark as reviewed; Copy and Share (only after review); Write again (asks first when there are edits); Transcribe again; Delete (asks first, removes the folder) |
| Settings | Device, model tiers (download and remove), privacy text, support, app name and version |

The flows in `tools/clinic-flows.mjs` are: onboarding, record, review, library (list, dark mode, delete), leaving (Back from the recorder and from the editor), and settings. They check state at each step. Each run saves a screenshot per step and a video per flow under `docs/media/clinic/<slug>/<target>/<flow>/`.

Every template's prompt carries the clinical rules:
- Never add findings, diagnoses, medications, doses, test results or plans that were not said.
- Keep the clinician's wording for clinical terms.
- Write "Not discussed." under a section with nothing said.

## Commands

```sh
bun tools/tenant.mjs list
bun tools/tenant.mjs check <slug>
bun tools/tenant.mjs icon <slug>
bun tools/tenant.mjs build <slug> web|android|ios
bun tools/tenant.mjs verify <slug> web
bun tools/tenant.mjs flows <slug> web|web-phone|android [flow…]
bun tools/clinic-e2e-web.mjs <slug>           # real models in Chrome on a synthetic consultation
bun test                                      # core, clinic and tenants
```

`build` writes a complete Exact app to `.exact/tenants/<slug>/app/`, which git ignores. It contains:
- `clinic/`'s view, data module and tests;
- `clinic/lib`;
- a generated `app.json`, `app.tamber`, strings table, typed `tenant.ts` and icon.

`core/` and `tenants/` are mounted through `typescript.sources`, not copied.

## Verdicts

| Check | Command | Verdict | Output tail |
|---|---|---|---|
| Unit tests (core, clinic, tenants) | `bun test` | VERIFIED | `84 pass, 0 fail` |
| Alona: core | `bun test core/` | VERIFIED | `54 tests … 0 fail` |
| Alona: Exact verify | `bun exact.mjs verify web` | VERIFIED | `tests: 3 passed, 0 failed` · `verify: clean in 18.0 s` |
| Alona: flows | `bun tools/flows.mjs web` | VERIFIED | `6 passed, 0 failed` |
| Alona: Android build | `bun exact.mjs android` | VERIFIED (after `f4f9ee3`) | `built in 56.4 s, installed on emulator-5554 as com.alona.app` |
| Tenants check | `bun tools/tenant.mjs check <slug>` ×3 | VERIFIED | `default: ok`, `quillmoor-pilot: ok`, `tidewell: ok` |
| default: Exact verify web | `bun tools/tenant.mjs verify default web` | VERIFIED | `verify: clean in 24.9 s` |
| quillmoor-pilot: Exact verify web | `… verify quillmoor-pilot web` | VERIFIED | `verify: clean in 24.6 s` |
| tidewell: Exact verify web | `… verify tidewell web` | VERIFIED | `verify: clean in 24.5 s` |
| default: flows, web desktop | `… flows default web` | VERIFIED | `6 passed, 0 failed` |
| default: flows, web phone | `… flows default web-phone` | VERIFIED | `6 passed, 0 failed` |
| quillmoor-pilot: flows, web desktop | `… flows quillmoor-pilot web` | VERIFIED | `6 passed, 0 failed` |
| quillmoor-pilot: flows, web phone | `… flows quillmoor-pilot web-phone` | VERIFIED | `6 passed, 0 failed` |
| default: flows, Android emulator (Pixel 9, API 36) | `… build default android` then `… flows default android` | onboarding, settings, leaving (Back): VERIFIED in every run. record, review, library: INCONCLUSIVE | Last full run `4 passed, 2 failed`. Over all runs: record passed 3 of 12, review 3 of 9, library 4 of 7. Each failure is `rec.state: expected "recording", got "inactive"` |
| quillmoor-pilot: flows, Android emulator | `… build quillmoor-pilot android` (207.5 s) then `… flows quillmoor-pilot android` | onboarding, library, leaving, settings: VERIFIED. record, review: INCONCLUSIVE | `4 passed, 2 failed`, with the same failure |
| Fourth tenant in a scratch copy (`larkfield`, not committed) | `check` → `build larkfield web` → `flows larkfield web record` | VERIFIED | `check` under 1 s, and the first run caught a too-long word in the welcome title. Build `ok in 2.9 s`. Flow `ok · 17 checks · 9 screenshots · 7.8 s`. About 2 minutes of editing. |
| Real models on web (quillmoor-pilot, Lite) | `bun tools/clinic-e2e-web.mjs quillmoor-pilot` | VERIFIED (both thresholds) | `WER 2.50%` (4 errors in 160 words), headings exactly `Presenting complaint, History, Findings, Impression, Treatment plan`, pipeline 38.1 s, recorded by the app through Chrome's fake microphone |
| iOS | — | NOT VERIFIED | Xcode 27.1 needed; this Mac has 26.1.1 |

On the Android failures: when one happens, `getUserMedia` answers, and logcat shows `recording: recorder-1-1 recording stream-1-1 to …audio.wav`. The view's `send started = startMediaRecorder(...)` is still pending after the agent's 20-second limit. On the same emulator, Alona's own `bun tools/flows.mjs android record` failed once and passed once, with the identical message. So the fault sits below the clinic app, in Exact's Android recorder reply or the emulator. Ruled out: the microphone permission (it was `granted=true`), an emulator started with `-no-audio` (a restart with audio still failed), and typing before the tap (it fails without typing too). Media from the last run of each flow is under `docs/media/clinic/<slug>/android/`. A failed flow keeps its screenshots up to the failure and its drive.log.

### The real-model note (Lite: Moonshine Base and Qwen3.5 0.8B, synthetic speech)

The fixture is two macOS `say` voices reading a 56-second physiotherapy consultation. Synthetic speech is far cleaner than a real room, so a 2.5% word error rate here says little about real use. The transcript was accurate. The draft passed the heading check but is a poor note:

- It copies the template's guidance sentences into the note ("Past episodes, general health, and activity the patient described.").
- It pastes the transcript's questions and answers verbatim under Presenting complaint and History.
- It repeats the history under Impression.
- It does say the stated impression, the findings (about 120 degrees, painful arc positive) and the plan accurately, and it adds nothing that was not said.

The full text is in `docs/media/clinic/quillmoor-pilot/web-real/e2e.json`. It shows that the "AI draft · Not reviewed" gate is necessary. The Lite tier is not good enough for clinical drafts without prompt work, and Balanced was not measured here.

## Visual defects

Found by opening the screenshots and by Exact's screen checks.

Fixed on this branch:
- The demo draft wrote the same text under "Reason for visit" and "History".
- The default tenant's disclaimer began "AI draft.", directly under the "AI draft · Not reviewed" label.
- The recording waveform drew black, because its tint accepts no token. The build now writes the tenant's color into it.
- The Quillmoor support link was 4.1:1 in dark mode (Exact verify). The validator now requires 4.5:1 for the accent as link text.
- The welcome title spilled at the largest text size (Exact verify). It now uses `title2`, and the validator limits its words to 8 letters.
- The tagline was bolder than the smaller title. It is now body text.

Still open:
1. On Android, filled buttons ("Start recording", "Mark as reviewed") draw the platform's navy, not the tenant accent. The accent does reach text buttons ("Cancel") there. This appears in both tenants.
2. The web recording modal shows "Stop and draft the note" twice: in the card, and again as a footer button that Exact draws for the header's Back button. Alona's recorder has the same duplicate.
3. On Android, while the new-note sheet's reference field animates, its floating placeholder overlaps the typed text for one frame (`android/record/02-reference-and-template.png`).
4. The welcome card says "Best fit: Balanced" over the Lite model line when a tenant's default tier is not the device's best fit (`quillmoor-pilot/web-phone/onboarding/01-welcome.png`). The label should name the tier that will download.
5. Under automation and on Android, the note's demo banner and the sample draft are both shown. This is correct, but busy on a phone.

## Not verified

- **iOS.** This Mac has Xcode 26.1.1, and Exact's iOS build needs 27.1. The manifest names iOS (`host.ios`, minimum iOS 17), and the view uses only what Alona's iOS build uses. Nothing was built or run.
- **Android with real models.** There is no Android inference engine, so Android always runs the demo engine. This is the same as Alona.
- **Share on web.** The flow taps Share and checks that the note stays reviewed. The system share sheet itself was not seen.
- **Hardware microphone in the real-model run.** See the run's `microphone` line in `docs/media/clinic/quillmoor-pilot/web-real/e2e.json`.

## Open risks and decisions for the owner

1. **Identifiers in the reference field.** The field is free text. The hint asks for no names, dates of birth or record numbers, but nothing enforces it. Decide whether to pattern-check it (dates, long digit runs), or to accept the risk because the data stays on the device.
2. **Audio retention after review.** The recording stays until the note is deleted. Decide whether to delete the audio when a note is marked as reviewed, or after N days. Either can be a tenant setting.
3. **Regulatory review.** The app claims no compliance, and the validator refuses compliance words in the privacy text. Using the app with real patients needs a review against the market's rules for clinical documentation and for medical-device software. That review has not happened.
4. **Small-model accuracy.** Lite and Balanced are small models. The Lite draft above echoed the template guidance and the transcript. The real-model run used clean synthetic speech, so its word error rate is a floor. A wrong word in a clinical note matters more than in meeting notes. The "AI draft · Not reviewed" gate and the copy and share lock are the only safeguards. Measure on real recorded consultations, with consent, before any pilot.
5. **No Android engine.** Android builds run the demo engine and show sample drafts. Shipping on Android needs an engine (the protocol is in `core/engine.ts`).
6. **Android record flows are flaky under Exact's agent.** See the verdicts. Alona's own record flow shows the same problem on the same emulator. It is noted for the Exact team in the local feedback diary, which was not sent.
7. **Alona's `app.ts` still has its own copy of the engine choice** that `core/host.ts` now holds for the clinic. The two copies should become one. That needs the `app.ts` change this task was told not to make.
8. **Exact's native bake refuses links under the app directory.** Alona's app directory is the repository root, so no file under `clinic/` or `tenants/` may be a symlink. An earlier commit on this branch had two, and they broke Alona's Android build until commit `f4f9ee3` removed them.
