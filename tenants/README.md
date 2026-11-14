# Adding a tenant

A tenant is one branded build of the clinic app. It is one TypeScript file, `tenants/<slug>.ts`, plus a square PNG icon. Nothing else changes: the view, the pipeline and the engines are shared.

Three tenants ship, all with invented names:

| File | App name | What it shows |
|---|---|---|
| `default.ts` | Clinic Notes | The neutral build: no organization's name, teal, SOAP and a general consultation template |
| `quillmoor-pilot.ts` | Quillmoor Notes | A test partner: purple, two physiotherapy templates, Lite by default, no share or playback, a support email |
| `tidewell.ts` | Tidewell Session Notes | A counselling practice: amber, "client" instead of "patient", session and DAP templates, a support email and web page |

## Add one

1. Copy the closest tenant to `tenants/<slug>.ts`. The slug is 2 to 32 lowercase letters, digits and hyphens, and it must equal the file name.
2. Edit the fields (below).
3. Draw a placeholder icon, or put your own 1024 px PNG at the path `icon` names:

   ```sh
   bun tools/tenant.mjs icon <slug>
   ```

4. Check it. This type-checks the file and then runs the rules that types cannot express. Each error names the field and the fix.

   ```sh
   bun tools/tenant.mjs check <slug>
   ```

5. Build and try it:

   ```sh
   bun tools/tenant.mjs build <slug> web          # the site, in .exact/tenants/<slug>/dist
   bun tools/tenant.mjs verify <slug> web         # Exact's tests and screen checks; ends "verify: clean"
   bun tools/tenant.mjs flows <slug> web          # every clinical flow, with screenshots and a video per flow
   bun tools/tenant.mjs build <slug> android      # builds the APK and installs it on the running emulator or device
   bun tools/tenant.mjs build <slug> ios          # needs the Xcode version Exact names (see "Not verified")
   ```

In a scratch copy, a fourth tenant took about two minutes of editing. The check took under a second and caught a welcome title that was too long. The first web build took 2.9 s and the record flow took 7.8 s.

## The fields

`defineTenant` checks the types. For example, `defaults.template` must be one of the template ids, or the file does not compile. `tenant.mjs check` checks the rest.

| Field | What it is | Rules `check` adds |
|---|---|---|
| `slug` | The build's folder name | Must equal the file name |
| `app.name` | Shown in the top bar, on the welcome screen and in Settings | Not empty |
| `app.shortName` | The name under the phone icon | At most 12 characters |
| `app.tagline` | Under the welcome title | Not empty |
| `app.bundleId` | The store id, such as `org.example.notes` | Lowercase words joined by dots, at least three |
| `app.version` | Shown in Settings | Three numbers, such as `1.0.0` |
| `colors.<token>.light/.dark` | The 13 brand colors (below) | Six hex digits; contrast (below) |
| `copy.welcomeTitle` | The first screen's heading | No word longer than 8 letters. A longer word spills off a phone at the largest text size. |
| `copy.welcomeBody` | The first screen's paragraph | Not empty |
| `copy.person` | `{ singular, plural }`: "patient" or "client" | Lowercase |
| `copy.reviewDisclaimer` | Under "AI draft · Not reviewed" on every unreviewed note | Not empty. Do not start it with "AI draft", because the label already says that. |
| `copy.privacy` | Settings → Privacy | Claims no regulation or certification: no HIPAA, GDPR, "compliant" or "certified" |
| `templates` | One or more note formats (below) | Unique ids; unique headings within a template |
| `defaults.template` | The template a new note starts with | Must be a template id (a type error otherwise) |
| `defaults.tier` | `auto`, `lite`, `balanced` or `quality` | Used until the clinician picks a tier in Settings |
| `features` | `jottings`, `copy`, `share`, `playback`, each true or false | |
| `support` | Optional `email`, `url` (https) and `hours` | Well-formed email; the URL starts with https:// |
| `icon` | A PNG path relative to `tenants/` | The file exists |

### Colors

The build writes the colors into the app's token file (`app.tamber`). The view names tokens, never values. There is one exception: the recording waveform accepts only a literal color, so the build writes a mid-tone of `attentionInk` there.

| Token | Where it shows |
|---|---|
| `accent` | Filled buttons, links, selection, the app tint |
| `page`, `card`, `raised` | The page, grouped cards, and the welcome and new-note cards |
| `line` | Borders and separators |
| `text`, `muted` | Body text and secondary text |
| `progressSoft`/`progressInk` | "Reviewed", and the model download |
| `attentionSoft`/`attentionInk` | The recording card, errors |
| `noticeSoft`/`noticeInk` | "AI draft · Not reviewed", and the demo-mode banner |

`check` enforces these contrast ratios in both schemes:
- 4.5:1 for text and muted text on page, card and raised, and for each ink on its soft color.
- 3:1 for the accent on page and card.
- 3:1 for white button labels on the accent.
- 4.5:1 for the accent as link text on the platform's list background: white in light mode, black in dark mode.

### Templates

```ts
{
  id: 'physio-initial',               // kept in each note's record; do not rename after release
  name: 'Initial assessment',         // shown in the new-note sheet
  description: 'First session: history, findings and a treatment plan.',
  sections: [
    { heading: 'Presenting complaint', guidance: 'The problem the patient came with, its onset and what makes it better or worse.' },
    // …
  ],
}
```

The model gets the headings in order, with one guidance sentence each. It also gets these fixed clinical rules:
- Never add findings, diagnoses, medications, doses, test results or plans that were not said.
- Keep the clinician's wording for clinical terms.
- Under a section with nothing said, write "Not discussed."

The app adds any missing heading, so every draft has exactly the template's sections. Write headings as plain text, without `#`. A note keeps its template id. If a later build removes that template, the note falls back to the default template.

## What a tenant cannot change

- The clinical prompt rules, and the "AI draft · Not reviewed" label.
- Where data goes. Everything stays on the device, and the only network use is downloading models. There are no analytics, logs or crash reports to switch on.
- The flows: new note, record, review, edit, mark as reviewed, write again, transcribe again, delete.
