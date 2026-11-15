// The notes pad's flow steps (clinic/lib/notes-pad.contract), shared by tools/flows.mjs and
// tools/clinic-flows.mjs: every formatting button on real text, the Markdown it stores, and
// the active state the toolbar shows.

// Select all, bold, and the ends of a line. Chrome under the agent runs no Mac editing chords for a line's ends.
export const KEYS = {
  web: { selectAll: 'Meta+a', boldKey: 'Meta+b', lineStart: 'Home', lineEnd: 'End' },
  macos: { selectAll: 'Meta+a', boldKey: 'Meta+b', lineStart: 'Meta+ArrowLeft', lineEnd: 'Meta+ArrowRight' },
  android: { selectAll: 'Control+a', boldKey: 'Control+b', lineStart: 'Home', lineEnd: 'End' },
};
export const keysFor = (host) => KEYS[host] ?? KEYS.web;

export const shot = (name) => ({ shot: name });
export const check = (path, equals) => ({ check: path, equals });
/** Whether the toolbar shows a button as on (`aria-pressed`). */
export const pressed = (target, equals) => ({ pressed: target, equals });
/** Exact's screen check, light and dark, failing on any finding inside the pad (its testIds start with `prefix-`, or are `field`). */
export const padClean = (prefix, field) => ({ padClean: [prefix, field] });

// Exact's screen check (`check both`) runs on these hosts only.
const SCREEN_CHECK_HOSTS = new Set(['web', 'ios']);

/**
 * A step the runners do not know as a plain state read: the op to send and the check on its
 * reply, `{ skip }` with the reason when the host cannot run it, or null.
 */
export function padOp(step, host) {
  if ('pressed' in step) {
    return { op: `tree ${step.pressed}`, check: { check: `${step.pressed} pressed`, equals: step.equals, read: (r) => JSON.parse(r).nodes[0].props.accessibilityPressed === 'true' } };
  }
  if ('padClean' in step) {
    const [prefix, field] = step.padClean;
    if (!SCREEN_CHECK_HOSTS.has(host)) return { skip: `${prefix} pad screen check: Exact runs it on web and iOS only` };
    const inPad = (f) => typeof f.node === 'string' && (f.node.startsWith(`${prefix}-`) || f.node === field);
    return { op: 'check both', check: { check: `${prefix} pad screen check`, equals: [], read: (r) => JSON.parse(r).check.flatMap((c) => c.findings.filter(inPad).map((f) => f.line.trim())) } };
  }
  return null;
}

/** Steps only some hosts can drive: `{ only: hosts, why, steps }`. */
const only = (hosts, why, steps) => ({ only: hosts, why, steps });

/** A flow's steps for one host, with `only` groups kept or skipped (and the skip said). */
export function forHost(steps, host) {
  return steps.flatMap((step) => {
    if (typeof step !== 'object' || !('only' in step)) return [step];
    if (step.only.includes(host)) return step.steps;
    console.log(`  skipped: ${step.why}`);
    return [];
  });
}

/** Fills `{selectAll}` and the other key names for a host. */
export const withKeys = (host, op) => op.replace(/\{(selectAll|boldKey|lineStart|lineEnd)\}/g, (_, k) => keysFor(host)[k]);

/**
 * Every formatting button on the pad whose buttons start with `p-`, whose editor's testId is
 * `field` and whose value the app keeps in the state `value`. An agent `type` replaces the field
 * and leaves the caret at its end, so each step types a fresh value first.
 */
export function formatSteps(p, field, value) {
  const select = [`type ${field} key {selectAll}`];
  const fresh = (text) => [`type ${field} ${text}`];
  return [
    ...fresh('Agenda'), ...select, `tap ${p}-bold`, 'clock data', check(value, '**Agenda**'), pressed(`${p}-bold`, true), shot(`${p}-bold`),
    ...fresh('Agenda'), ...select, `tap ${p}-italic`, 'clock data', check(value, '*Agenda*'), pressed(`${p}-italic`, true),
    ...fresh('Agenda'), ...select, `tap ${p}-strike`, 'clock data', check(value, '~~Agenda~~'), pressed(`${p}-strike`, true), shot(`${p}-strike`),
    ...fresh('Agenda'), `tap ${p}-title`, 'clock data', check(value, '## Agenda'), pressed(`${p}-title`, true), pressed(`${p}-plain`, false), shot(`${p}-title`),
    `tap ${p}-subtitle`, 'clock data', check(value, '### Agenda'), pressed(`${p}-subtitle`, true), pressed(`${p}-title`, false),
    `tap ${p}-plain`, 'clock data', check(value, 'Agenda'), pressed(`${p}-plain`, true), pressed(`${p}-subtitle`, false),
    ...fresh('Agenda'), `tap ${p}-bullet`, 'clock data', check(value, '- Agenda'), pressed(`${p}-bullet`, true), shot(`${p}-bullet`),
    pressed(`${p}-plain`, false), `tap ${p}-plain`, 'clock data', check(value, 'Agenda'), pressed(`${p}-plain`, true), pressed(`${p}-bullet`, false),
    ...fresh('Agenda'), `tap ${p}-ordered`, 'clock data', check(value, '1. Agenda'), pressed(`${p}-ordered`, true), pressed(`${p}-bullet`, false),
    ...fresh('Agenda'), `tap ${p}-task`, 'clock data', check(value, '- [ ] Agenda'), pressed(`${p}-task`, true), shot(`${p}-checklist`),
    ...fresh('Agenda'), `tap ${p}-quote`, 'clock data', check(value, '> Agenda'), pressed(`${p}-quote`, true), shot(`${p}-quote`),
    ...fresh('Alona site'), ...select, `tap ${p}-link`, 'clock settle', `type ${p}-link-url https://example.com`, `tap ${p}-link-apply`,
    'clock data', check(value, '[Alona site](https://example.com)'), pressed(`${p}-link`, true), shot(`${p}-link`),
    // The state follows the caret: the start of the line is plain, its end inside the bold. The
    // macOS agent moves the caret without a selection event, so only the web drives this.
    only(['web'], `${p} caret-follow: the macOS agent sends no selection event for a caret move`, [
      ...fresh('Plain **bold**'), `type ${field} key {lineStart}`, 'clock data', pressed(`${p}-bold`, false), shot(`${p}-caret-in-plain`),
      `type ${field} key {lineEnd}`, 'clock data', pressed(`${p}-bold`, true), shot(`${p}-caret-in-bold`),
    ]),
    // The platform shortcut is the editor's, and the toolbar follows it.
    ...fresh('Agenda'), ...select, `type ${field} key {boldKey}`, 'clock data', check(value, '**Agenda**'), pressed(`${p}-bold`, true), shot(`${p}-shortcut-bold`),
  ];
}
