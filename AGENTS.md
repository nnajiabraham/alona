<!-- exact:begin (exact new writes this block; bun exact.mjs update rewrites it) -->
# alona: an Exact app

`app.contract` is the view, `app.ts` the data module, `app.test.contract` the tests, `app.json`
the manifest: set `app.name` and `app.id` before building. The app uses Exact at
`/Users/manlikeabro/Documents/repos/exact` by path (`EXACT` overrides it).

This file is already in your instructions. Start from the nearest pattern: `bun exact.mjs
pattern` lists them and `pattern <name>` writes one, tested. /Users/manlikeabro/Documents/repos/exact/docs/start-here-site.md (a site) or
/Users/manlikeabro/Documents/repos/exact/docs/start-here.md is the only required reading. `bun exact.mjs contract vocab <name>` answers a
name (none: the card); `bun exact.mjs docs <heading words>` a guide's
section. Run `bun exact.mjs verify` when the features work, and `verify ios|android` at the end for a
phone app. When an iPhone app is ready to try, run `bun exact.mjs share` and send its link;
repeat for each change the person should see. `bun exact.mjs help` lists the verbs, including
app.json's `"commands"`.
`bun exact.mjs update` refreshes files. Native verbs (`ios`, `mac`, `linux`, `android`, `windows`)
name their platform in app.json on first use and build in a generated workspace;
`update --without <platform>` stops shipping it.
`bun /Users/manlikeabro/Documents/repos/exact/scripts/exact.mjs setup --check` names what a native build lacks.

Generated, so don't edit: `exact.mjs` and this block.

## Feedback (required)

When a doc was wrong or missing, a workaround was needed, something took several tries or a
command confused you, record it: `bun exact.mjs feedback note "<what happened>"`. It attaches
exact2's commit and the last exit code, never output or code. `bun exact.mjs feedback status` says
whether notes are sent and whether to keep a diary; under `never`, skip all of this.
<!-- exact:end -->

# Alona: project guidelines

Alona is a private meeting assistant. It records a meeting, transcribes it with a local speech model, and a local LLM writes the notes. One Exact app builds web, macOS, iOS, and Android. The field guide at `docs/explainer/index.html` explains the design, the flows, the brand, and setup.

## Layout

| Path | What it holds |
|---|---|
| `app.contract`, `app.ts`, `app.tamber`, `app.json` | The view, the data module, the brand tokens, the manifest |
| `core/` | Shared TypeScript: `service`, `pipeline`, `notes`, `device`, `models`, `store`, `engine` (the protocol), `sim-engine`, `artifacts.json` |
| `modules/apple/` | The Swift inference engine for macOS and iOS |
| `modules/web/`, `engine/web/` | The web engine's seam and its Worker source |
| `tools/` | Flow runner, real-model checks, model pinning, framework fetch, the Exact patch |
| `docs/` | Field guide, captured media, research, spike reports, decision trail |
| `legacy/macos-swift/` | The original Swift app, reference only |

## Checks to run before calling work done

```sh
bun test core/                  # shared logic
bun exact.mjs verify web        # Contract tests plus Exact's screen checks; ends with "verify: clean"
bun tools/flows.mjs web         # every flow, with state checks and fresh media
bun tools/e2e-native.mjs lite   # macOS on real models, after any engine or pipeline change
```

`bun tools/explainer-data.mjs` refreshes the field guide after new media or check results.

## Rules

1. Logic goes in `core/` as pure TypeScript with a test in `core/core.test.ts`. `app.ts` only wires sources to the service.
2. An engine answers the protocol in `core/engine.ts` and nothing else. Prompts, chunking, tier rules, and storage stay in `core/`.
3. Every model file is pinned by `tools/pin-models.mjs` into `core/artifacts.json`. Do not hand-edit that file.
4. A host is listed under a model in `core/models.ts` only after its engine has run that model end to end.
5. The person's actions and the pipeline write different files in a meeting's folder (`core/store.ts`). Keep it that way.
6. Colors come from `app.tamber` tokens or platform roles. No hex values in `app.contract`, except the waveform tint, which takes only a literal.
7. Recording flows are tested in `tools/flows.mjs`, because Contract test files cannot grant the microphone permission.
8. Nothing about a meeting leaves the device. The only network use is downloading models.
