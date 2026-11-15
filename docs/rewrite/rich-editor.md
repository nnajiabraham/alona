# Rich notes editor and clinic re-templating

Branch `rewrite/rich-editor`, from `origin/rewrite/release`.

This change has two parts:

1. A formatting toolbar on every notes pad in Alona and the clinic app.
2. In the clinic app, a way to write a visit's note again as another template, next to the first note.

## 1. The formatting toolbar

One component, `NotesPad` in `clinic/lib/notes-pad.contract`, draws the editor, the toolbar above it, and a hint line under it. Five pads use it:

| App | Pad | Button testIds |
|---|---|---|
| Alona | Recording notes | `rec-*` |
| Alona | My notes | `mine-*` |
| Clinic | Recording jottings | `rec-*` |
| Clinic | Draft editor | `draft-*` |
| Clinic | Jottings pane | `jot-*` |

The file lives under `clinic/lib` because `tools/tenant.mjs` copies that folder into every tenant build at the same relative path. That way `use NotesPad from "./clinic/lib/notes-pad.contract"` resolves the same in both apps. A neutral folder such as `ui/` would read better, but it needs a one-line change in `tools/tenant.mjs`, which is outside this change's scope.

### Buttons and the commands behind them

Each button calls the editor's own `format` command, so the stored value stays Markdown and each press is one undo step. No button inserts Markdown text.

| Button | Label shown | Command | Stored Markdown (checked by the flows) |
|---|---|---|---|
| Bold | **B** | `format(id, "bold")` | `**Agenda**` |
| Italic | *I* | `format(id, "italic")` | `*Agenda*` |
| Strikethrough | ~~S~~ | `format(id, "strike")` | `~~Agenda~~` |
| Title | Title | `format(id, "heading", "2")` | `## Agenda` |
| Subtitle | Subtitle | `format(id, "heading", "3")` | `### Agenda` |
| Plain text | Text | Repeats the current heading, list or quote command, which takes it off | `Agenda` |
| Bulleted list | list symbol + "Bullets" | `format(id, "bullet")` | `- Agenda` |
| Numbered list | "1." + "Numbers" | `format(id, "ordered")` | `1. Agenda` |
| Checklist | checkmark + "To-do" | `format(id, "task")` | `- [ ] Agenda` |
| Quote | quote symbol + "Quote" | `format(id, "quote")` | `> Agenda` |
| Link | link symbol + "Link" | Opens an address row, then `format(id, "link", url)` | `[Alona site](https://example.com)` |
| Timestamp (Alona only) | `[m:ss]` | `setRangeText(id, "[m:ss] ")` | `Agenda[0:05] ` |

Every button has these properties:

- It has an accessible name (`aria-label`) and reports its state with `aria-pressed`.
- Its target is at least 44 pt.
- It keeps focus in the editor (`retainFocus`), so the keyboard stays up.
- Its active state comes from the editor's `select` event (`MarkdownSelection.formats`), so it follows the caret. The flows check this: with the caret in plain text, Bold is off; inside `**bold**`, Bold is on.
- It is disabled when the selection lists its command as unavailable.

Cmd/Ctrl+B and Cmd/Ctrl+I are the editor's own shortcuts, and the toolbar follows them. The flows check Cmd+B.

The toolbar is one row that scrolls sideways. It is sticky at the top of the pad, so it stays above the caret while a phone keyboard is up. A hint under the editor says: "The buttons are optional. You can also type Markdown, such as **bold** or - for a list."

Undo and redo have no buttons. They are not in Contract's documented `format` vocabulary, and the Apple editor path does not expose them. Cmd/Ctrl+Z works on each host as the platform provides.

### Host support

| Command | Web | macOS | iOS | Android | Windows / Linux |
|---|---|---|---|---|---|
| Bold, italic, strike, headings, lists, task, quote, link | shown, verified | shown, verified (caret-follow not driven) | shown, not run | shown, not run | shown, not run |
| Timestamp | shown, verified | shown, verified | shown, not run | **hidden** | **hidden** when the host reports `windows` |
| Undo / redo buttons | hidden (not in vocabulary) | hidden | hidden | hidden | hidden |

Contract documents `setRangeText` as unsupported on Android and Windows, so the timestamp button is hidden on those hosts. To make this possible, `core/service.ts` now passes `setup.host` through to the view. The Electron desktop package runs the web build. If it reports host `web`, the timestamp shows there.

### What changed outside the view for Part 1

- `core/service.ts`: `SetupView.host` is new. It is the only core change in Part 1, and a test in `core/core.test.ts` covers it.
- `tools/pad-steps.mjs` is a new file, outside the listed scope. It holds the toolbar steps that both flow runners share, plus the keys each host uses for select-all, bold, and line start and end.

## 2. Writing a note again as another template (clinic)

From a note's screen, **Write as another note** opens a sheet that lists the tenant's other templates. Choosing one drafts a new note, beside the first, from the same transcript and jottings.

### The model

A re-templated note is a second meeting folder:

| What | First note | Second note |
|---|---|---|
| Recording | Its own file | The same file path (not copied) |
| Transcript | Its own | A copy, made at fork time |
| Jottings (`userNotes`) | Its own | A copy, made at fork time |
| AI notes | Its own | Written fresh with the new template's profile |
| Edits (`edited.md`) and review (`review.json`) | Unchanged | Its own; starts as an unreviewed draft |
| `clinic.json` | Unchanged | Same `patientRef`, new `templateId`, and `fromTemplateId` set to the first note's template |

Two functions do the work:

- `core/service.ts` `fork(from, id)` makes the meeting. It refuses unless the source is done and the id is new. It creates the folder, copies the transcript, and then queues the notes stage only, so no transcription runs a second time.
- `clinic/lib/service.ts` `writeAs(from, templateId, id)` checks the template belongs to the tenant, then writes `clinic.json` and calls `fork`. If `fork` refuses, it removes the folder, so nothing is left behind.

The second note is a normal clinic note. Copy and share stay locked until it is reviewed, and edits stay separate from the model's draft. The first note's screen is unchanged, except that it shows "Written again from the X note of this visit." when it is the second note.

### Deleting a note that shares its recording

`core/service.ts` `remove(id)` keeps a shared recording:

- If the recording sits in the folder being deleted and another note uses it, the recording is first copied into that other note's folder (`store.copyAudio`).
- Every note that shares it is pointed at the new path.
- Then the folder is removed.

When the recording is shared, the delete dialog says: "The recording stays, because another note from this visit uses it."

### Tests

- `clinic/clinic.test.ts`, "writing a note again as another template", has four tests:
  - The referral sits beside the reviewed consultation, with the same reference and audio.
  - The second note's edits and review are its own.
  - Deleting either note keeps the recording.
  - Refusals leave nothing behind.
- `core/core.test.ts`, "a second meeting from the same recording", has three tests:
  - What `fork` copies and shares.
  - When `fork` refuses.
  - Deleting either meeting keeps the other's audio bytes.
- The `tools/clinic-flows.mjs` `rewrite` flow (30 checks) runs these steps:
  1. Record a visit and mark the first note reviewed.
  2. Write it as a referral.
  3. Check the new note's template, reference, audio path, draft state and referral headings.
  4. Delete the referral.
  5. Check the first note is unchanged: reviewed, same text, same review time, same audio path, and a player is present.

## Verdicts

| Check | Command | Result |
|---|---|---|
| Unit tests | `bun test` | VERIFIED: `Ran 109 tests across 4 files`, `0 fail` (7 new re-templating tests, 1 new host test) |
| Alona screen checks | `bun exact.mjs verify web` | VERIFIED: `tests: 3 passed`, `7 screens: nothing spills`, `verify: clean` |
| Alona flows, web | `bun tools/flows.mjs web` | VERIFIED: `8 passed, 0 failed`; toolbar 42 checks |
| Alona flows, web-phone | `bun tools/flows.mjs web-phone` | VERIFIED: `8 passed, 0 failed` |
| Alona flows, macOS | `bun tools/flows.mjs macos` | VERIFIED: `14 passed, 0 failed`; toolbar 40 checks, with the caret-follow and screen-check steps skipped (see Not verified) |
| Clinic screen checks | `bun tools/tenant.mjs verify default web` | VERIFIED: `verify: clean` |
| Clinic flows, web | `bun tools/tenant.mjs flows default web` | VERIFIED: `9 passed, 0 failed`; rewrite 30 checks, toolbar 74 checks |
| Clinic flows, web-phone | `bun tools/tenant.mjs flows default web-phone` | VERIFIED: `9 passed, 0 failed` |

Media from these runs is under `docs/media/web/toolbar`, `docs/media/web-phone/toolbar*`, `docs/media/clinic/default/web*/toolbar*` and `docs/media/clinic/default/web*/rewrite`.

## Visual defects at phone width, light and dark

Found and fixed in this change:

- The link row's button said "Remove link" when there was no link. It now says "Add link" and is disabled until an address is typed.
- "Text" showed as pressed next to a list button. It now shows as pressed only on a line with no heading, list or quote, and pressing it clears a list or quote.

Still open, from this change:

- At phone width about five buttons fit, and the rest scroll sideways. Nothing on screen shows that the row scrolls.
- At the largest text size the toolbar shows two or three buttons at a time.
- The "Write as another note" sheet title sits close to "Cancel" at 390 pt. It does not clip.

Present before this change:

- At the largest text size, the floating Stop button covers the recording pad's hint.
- At the largest text size, the Note / Transcript / Jottings segmented control clips.
- At the largest text size, the header covers "Your notes" after scrolling.
- The clinic draft and jottings editors have no border, unlike Alona's.
- The recording timer shows 0:00 under the agent.

## Not verified

- A real on-screen keyboard with the sticky toolbar. The web-phone runs have no software keyboard.
- Android, iOS, Windows and Linux. The toolbar was not run on these hosts, and the Android timestamp hiding comes from the documentation, not from a run.
- Actual audio playback after a shared recording is moved. The unit test proves the bytes remain, and the flow proves the path and the player. Playback itself was not checked.
- Caret-follow on macOS. The macOS agent delivers `Meta+ArrowLeft` as a bare `ArrowLeft`, and a caret move fires no selection event, so the flow skips those two checks there and prints the skip. On macOS the active state is checked after each button and after Cmd+B.
- The toolbar's screen check at the largest text size on macOS. Exact runs `check both` on web and iOS only, so the macOS `toolbar-large` flow takes screenshots without that check.
- Re-templating on real models. The flows use the sample engine. The fork queues only the notes stage. The core test checks that the new meeting starts at `summarizing` with the first meeting's transcript segments.
