# The notes pad's toolbar on Android

Branch `rewrite/android-toolbar`.

Before this change, every formatting button on Android did nothing. Exact's Android host has no `format` command and no Markdown editor: the `markup="markdown"` textarea edits the source as plain text. Exact's `setRangeText` refuses a Markdown field (`host/painted/src/presenter/field.rs`), so the timestamp button was hidden on Android.

Now each button on Android applies the same Markdown as on the web, toggles it off, and shows its pressed state. The timestamp button shows on Android too. The web, macOS and iOS still use Exact's `format`.

## What Android delivers for selection

Found with a probe in the pad that logged each event into a text node, read with `tree` (Exact at `3baa28f`, emulator `emulator-5554`, Alona built with `bun exact.mjs android`):

| Event or step | What Android did |
|---|---|
| `input` (InputEvent) | Fires on each edit, with `selectionStart` and `selectionEnd`. After `type record-notes Agenda` it reported `6 6`. |
| `selectionchange` (InputEvent) | Fires when the selection or caret moves, with offsets. `key Shift+Home` reported `0 6`, `key Home` `0 0`, `key ArrowLeft` `5 5`. |
| `select` (`MarkdownSelection`) | Never fired. |
| `key Control+a`, `key Meta+a` | `delivery: "recognized"`, and the selection did not change. |
| `key Shift+Home` | Selects from the caret to the line start, reported through `selectionchange`. |
| `key Control+b` | Leaves the value unchanged (`"Agenda"`). Android's editor has no bold shortcut. |
| `setSelectionRange(editor, start, end)` | Works on the Markdown field. After bold, the field shows `Agenda` selected inside `**…**` (screenshot `docs/media/android/toolbar/02-rec-bold.png`), and a second bold tap unwraps exactly that range. |

## Design

- `core/markdown.ts` is new pure TypeScript.
  - `applyFormat(source, start, end, command, argument)` returns `{ value, start, end }`. Its commands are `bold`, `italic`, `strike`, `heading` (`"1"` to `"6"`), `bullet`, `ordered`, `task`, `quote` and `link` (an empty address removes the link), plus two of its own: `plain` clears a line's heading, list and quote, and `insert` replaces the selection with the argument. Repeating a command where it is on takes it off. A block command applies to every line the selection touches.
  - `formatsAt(source, start, end)` returns `{ formats, link, unavailable }`, in `MarkdownSelection`'s words: `bold italic strike headingN bullet ordered task quote`.
  - Emphasis follows CommonMark's delimiter-run rule, without its rule of three. Offsets are UTF-16 units, as the field reports them.
  - 15 tests in `core/core.test.ts` ("the notes pad formatting the Markdown source itself"): each button's Markdown, toggling off, one block format replacing another, Text, multi-line selections, nesting, a caret with no selection, link editing, insert, unknown commands, caret-follow, offset clamping and UTF-16.
- `app.ts` and `clinic/app.ts` each wire two sources to those functions: `formatMarkdown` and `markdownFormats`.
- `ui/notes-pad.contract`:
  - The pad takes `ownFormat`, `active`, `here`, `report` and `ask`.
  - It passes the field's `input` and `selectionchange` offsets to `report`.
  - With `ownFormat` set, each button calls `ask(editor, value, command, argument)` instead of `format`, and the timestamp calls `ask(…, "insert", stamp)` instead of `setRangeText`.
  - The pressed states come from `here` when the pad is the `active` one, and from the editor's `select` otherwise.
- Each app's root holds the requests, because Contract lets only the root declare a resource or a mutation (`type-child-resource`). The root keeps:
  - the pad in use (`padField`) and its selection (`padStart`, `padEnd`);
  - `resource padHere = markdownFormats(...) when padOwn and padField != ""`;
  - `mutation padEdit = formatMarkdown(...) then padLanded`. `padLanded` writes the value through that pad's own edit action, so autosave works as for typing, then restores the selection with `setSelectionRange`.
- `padOwn = setup.host == "android"`. Alona's `stamps` is now `setup.host != "windows"`, so the timestamp shows on Android.

## Flow changes (`tools/pad-steps.mjs`, `tools/flows.mjs`)

- Android selects with `Shift+Home`. `Control+a` selects nothing there, and each step's value is one line with the caret at its end.
- Caret-follow now runs on Android as well as the web. Android reports caret moves.
- The bold shortcut step runs on web, macOS and iOS. It is skipped on Android, with the reason printed, because Android's editor has no shortcut.
- A bold-by-button step now ends every pad's steps on all hosts. The clinic runner's save check reads `**Agenda**` after the pad steps, and on Android the shortcut step that used to leave that value does not run.
- `toolbar-large` now checks formatting at the largest text size on every host:
  - Recording pad: Quote, then Text.
  - My notes: Title, after the screen check.
  - Before this, `toolbar-large` made 0 checks on Android, because its only checks are Exact's screen checks, which run on web and iOS only.

## Commands and results

Environment as in the task brief. The final runs were on the committed code. The Android media under `docs/media/android/toolbar*` comes from the final Android run.

| Check | Command | Result |
|---|---|---|
| Unit tests | `bun test` | `Ran 127 tests across 4 files`, `0 fail` |
| Screen checks, web | `bun exact.mjs verify web` | `verify: clean` |
| Web toolbar | `bun tools/flows.mjs web toolbar toolbar-large` | `web toolbar: ok · 43 checks`, `web toolbar-large: ok · 8 checks`, `2 passed, 0 failed` |
| Phone-width toolbar | `bun tools/flows.mjs web-phone toolbar toolbar-large` | `web-phone toolbar: ok · 43 checks`, `web-phone toolbar-large: ok · 8 checks`, `2 passed, 0 failed` |
| Android, every flow | `bun exact.mjs android && bun tools/flows.mjs android` | `8 passed, 0 failed`: `android toolbar: ok · 41 checks`, `android toolbar-large: ok · 6 checks`; onboarding, record, review, library, leaving and settings ok |
| Clinic, web | `bun tools/tenant.mjs flows default web` | `9 passed, 0 failed` (toolbar 74 checks) |
| Clinic toolbar, Android (extra) | `bun tools/tenant.mjs build default android && bun tools/tenant.mjs flows default android toolbar` | `default android toolbar: ok · 72 checks`, `1 passed, 0 failed` |

The first clinic Android run failed one check: `detail.note: expected "**Agenda**", got "Plain **bold**"`. The cause was the skipped shortcut step, not the app. The bold-by-button closing step fixed it.

The covered-button error at large text (`tap rec-bold: view is covered or not hit at its projected center`) did not recur. `toolbar-large` taps `rec-bold`, `rec-quote`, `rec-plain`, `mine-title` and `mine-link` at a 53 px root on Android, and every tap landed in every run.

## Not verified, and known limits

- **A reply that lands after more typing.** An edit is a round trip to the data module. If the person types between a tap and its reply, the reply's value, computed from the source at the tap, replaces what they typed. The agent cannot type between a tap and its reply, so this was not seen, and no guard was added.
- **Undo.** On Android, a toolbar edit is a whole-value write, not one platform undo step, as `format` is elsewhere. Not tested.
- **Real touch selection.** Selection handles and a long-press were not driven. Only the agent's keys were (`Shift+Home`, `Home`, `End`). Both kinds of selection reach the app through the same `selectionchange`, but the touch path was not run.
- **Bold shortcut.** There is no Ctrl+B on Android with a hardware keyboard. The pad has no key handler for it.
- **Undocumented choices where Exact's web behaviour is unknown.** These came from no web reference:
  - Bold with a bare caret inserts `****` with the caret between the markers.
  - A link with no selection uses the address as its text.
  - A heading or list replaces the line's other block prefix but keeps a quote.
  - The web's `format` was not compared on these cases.
- **Other hosts.** Linux and Windows also edit the Markdown as a plain textarea (Linux per the docs), but `padOwn` covers Android only. Neither host was run.
- **iOS and macOS** were not rebuilt or run. Their path is unchanged: `ownFormat` is false there, and the pad calls `format` as before.
- **Clinic on Android:** only the `toolbar` flow was run, not every clinic flow.
- **A visual defect this change exposed, not fixed:** at phone width and the largest text size, with text in the My notes pad and the page scrolled, the sticky toolbar overlaps the link-address row. Exact's screen check found it on `web-phone` when Title was tapped before the screen check (`mine-quote`/`mine-link` overlap `mine-link-url`). The flow now taps Title after the check. The overlap is in the pad's layout and was not introduced by the Android path.
