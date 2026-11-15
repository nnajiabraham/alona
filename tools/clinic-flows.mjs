#!/usr/bin/env bun
// Drives each clinical flow through Exact's agent on one tenant's build,
// asserts the app's state at each checkpoint, and keeps a screenshot per step
// plus a stepped video per flow under docs/media/clinic/<slug>/<target>/<flow>/.
// Run it through tools/tenant.mjs, which builds the tenant's app first:
//
//   bun tools/tenant.mjs flows default web            every flow at desktop size
//   bun tools/tenant.mjs flows default web-phone      the same at a phone's size
//   bun tools/tenant.mjs flows tidewell android review
//
// Android drives the APK `bun tools/tenant.mjs build <slug> android` installed.
// The agent owns the clock, so a video is one frame per step. With the demo
// engine the transcript and draft are samples.
import { spawnSync } from 'node:child_process';
import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { forHost, formatSteps, padClean, padOp, pressed, START, withKeys } from './pad-steps.mjs';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const BUN = process.execPath;

const TARGETS = {
  web: { host: 'web', flags: ['--size', '1100x760'] },
  'web-phone': { host: 'web', flags: ['--size', '390x844'] },
  android: { host: 'android', flags: [] },
  ios: { host: 'ios', flags: [] },
};

const shot = (name) => ({ shot: name });
const check = (path, equals) => ({ check: path, equals });
const has = (path, text) => ({ check: path, contains: text });
/** Remembers a state's value under a name, for a later `same` to compare against. */
const keep = (path, name) => ({ check: path, keep: name });
const same = (path, name) => ({ check: path, same: name });

function flows(tenant) {
  const second = tenant.templates.find((t) => t.id !== tenant.defaults.template) ?? tenant.templates[0];
  const headings = second.sections.map((s) => `## ${s.heading}`);
  // The rewrite flow's pair: a consultation note written again as a referral letter, where the tenant has both.
  const first = tenant.templates.find((t) => t.id === 'consultation') ?? tenant.templates[0];
  const other = tenant.templates.find((t) => t.id === 'referral') ?? tenant.templates.find((t) => t.id !== first.id);
  const READY = ['clock data', 'tap continue', 'clock data', 'clock +6000', 'clock data'];
  const RECORDED = [
    ...READY,
    'tap new-note-button', 'clock settle', 'type new-ref Bed 4', `tap template-${second.id}`, 'clock settle', ...START,
    'clock data', 'clock settle', 'type record-jottings - L knee, 2 weeks',
    'clock +5000', 'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data',
  ];
  return {
    onboarding: [
      'clock data', check('setup.ready', true), check('welcomed', false), check('brand.name', tenant.app.name), shot('welcome'),
      'tap continue', 'clock data', check('welcomed', true), check('setup.activeDownloading', true), shot('downloading-models'),
      'clock +6000', 'clock data', check('setup.activeInstalled', true), shot('ready'),
    ],
    record: [
      ...READY,
      'tap new-note-button', 'clock settle', shot('new-note-sheet'),
      'type new-ref Bed 4', `tap template-${second.id}`, 'clock settle', shot('reference-and-template'),
      ...START, 'clock data', 'clock settle', check('rec.state', 'recording'), check('recRef', 'Bed 4'),
      check('recTemplate', second.id), shot('recording-started'),
      'type record-jottings - L knee, 2 weeks', 'clock +5000', shot('jottings-while-recording'),
      'tap stop-recording', 'clock data', 'clock settle', check('lib.0.state', 'processing'), shot('saved-and-queued'),
      'clock +3000', 'clock data', check('detail.status', 'transcribing'), shot('transcribing'),
      'clock +2000', 'clock data', check('detail.status', 'summarizing'), shot('writing-draft'),
      'clock +6000', 'clock data', check('detail.state', 'draft'), check('detail.patientRef', 'Bed 4'),
      check('detail.templateName', second.name), check('detail.jottings', '- L knee, 2 weeks'),
      ...headings.map((h) => has('detail.note', h)), shot('draft-ready'),
      'tap pane-transcript', check('pane', 'transcript'), shot('transcript'),
    ],
    review: [
      ...RECORDED,
      check('detail.state', 'draft'), shot('ai-draft'),
      'tap edit-note', 'clock settle', shot('editor'),
      'type note-editor Checked and edited by the clinician.', 'clock +1000', 'clock data',
      check('editDirty', false), check('detail.hasEdits', true), shot('edit-saved'),
      'tap done-editing', 'clock data', 'clock settle', check('editing', false), check('detail.note', 'Checked and edited by the clinician.'), shot('edited-note'),
      'tap mark-reviewed', 'clock data', check('detail.state', 'reviewed'), check('lib.0.state', 'reviewed'), shot('reviewed'),
      ...(tenant.features.copy ? ['tap copy-note', 'clock settle', check('copied', true), shot('copied')] : []),
      ...(tenant.features.share ? ['tap share-note', 'clock settle', check('detail.state', 'reviewed')] : []),
      'tap write-again', 'clock settle', shot('confirm-replace-edits'),
      'tap replace-confirm', 'clock data', 'clock +1000', 'clock data', check('detail.status', 'summarizing'), shot('writing-again'),
      'clock +6000', 'clock data', check('detail.state', 'draft'), check('detail.hasEdits', false), shot('fresh-draft'),
    ],
    library: [
      ...RECORDED,
      'back', 'clock data', 'clock settle', check('lib.length', 1), check('lib.0.patientRef', 'Bed 4'),
      check('lib.0.templateName', second.name), check('lib.0.state', 'draft'), shot('notes'),
      'prefer prefers-color-scheme dark', shot('notes-dark'),
      'tap "Bed 4"', 'clock data', 'clock settle', shot('note-dark'), 'prefer prefers-color-scheme light',
      'tap delete-note', 'clock settle', shot('confirm-delete'),
      'tap delete-confirm', 'clock data', 'clock settle', check('lib.length', 0), shot('deleted'),
    ],
    // Leaving a screen by the platform's Back runs no action of the app's, so these two paths need their own proof.
    leaving: [
      ...READY,
      'tap new-note-button', 'clock settle', ...START, 'clock data', 'clock settle', 'clock +3000',
      check('rec.state', 'recording'), shot('recording'),
      'back', 'clock data', 'clock settle', check('recorderId', ''), check('trackId', ''), check('lib.length', 1), shot('back-stopped-and-saved'),
      'clock +12000', 'clock data', check('detail.state', 'draft'),
      'tap edit-note', 'clock settle', 'type note-editor ## Typed just before Back', 'back', 'clock data', 'clock +1500', 'clock data',
      check('lib.length', 1), shot('notes-after-back'),
      `tap "No ${tenant.copy.person.singular} reference"`, 'clock data', 'clock settle', check('detail.hasEdits', true),
      check('detail.note', '## Typed just before Back'), shot('edits-kept'),
    ],
    // Every formatting button on each pad: the jottings while recording, the draft, and the jottings on the note.
    toolbar: [
      ...READY,
      'tap new-note-button', 'clock settle', 'type new-ref Bed 4', ...START, 'clock data', 'clock settle', shot('jottings-pad'),
      ...(tenant.features.jottings ? formatSteps('rec', 'record-jottings', 'recJottings') : []),
      'clock +5000', 'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data', check('detail.state', 'draft'),
      'tap edit-note', 'clock settle', shot('draft-pad'),
      ...formatSteps('draft', 'note-editor', 'editDraft'),
      'clock +1500', 'clock data', check('detail.note', '**Agenda**'), check('detail.hasEdits', true),
      'tap done-editing', 'clock data', 'clock settle',
      ...(tenant.features.jottings
        ? ['tap pane-jottings', 'clock settle', 'type jottings Follow up', 'tap jot-task', 'clock data', check('jotDraft', '- [ ] Follow up'),
          pressed('jot-task', true), 'clock +1500', 'clock data', check('detail.jottings', '- [ ] Follow up'), shot('jottings-pane')]
        : []),
    ],
    // The pads at the largest text size iOS offers (a 53 px root at a phone's width), light and dark.
    'toolbar-large': [
      ...READY, 'prefer root-font-size 53px',
      'tap new-note-button', 'clock settle', ...START, 'clock data', 'clock settle',
      ...(tenant.features.jottings
        ? ['type record-jottings - BP 120/80', 'tap rec-bold', 'clock settle', padClean('rec', 'record-jottings'), shot('jottings-large'),
          'prefer prefers-color-scheme dark', 'clock settle', shot('jottings-large-dark'), 'prefer prefers-color-scheme light']
        : []),
      'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data',
      'tap edit-note', 'clock settle', 'tap draft-link', 'clock settle', padClean('draft', 'note-editor'), shot('draft-large'),
      'prefer prefers-color-scheme dark', 'clock settle', shot('draft-large-dark'),
    ],
    // A second document from one visit: the reviewed note stays as it was, the new one is an unreviewed draft in the other template.
    rewrite: [
      ...READY,
      'tap new-note-button', 'clock settle', 'type new-ref Bed 4', `tap template-${first.id}`, 'clock settle', ...START,
      'clock data', 'clock settle', ...(tenant.features.jottings ? ['type record-jottings - L knee, 2 weeks'] : []),
      'clock +5000', 'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data',
      check('detail.state', 'draft'), check('detail.templateName', first.name),
      'tap mark-reviewed', 'clock data', check('detail.state', 'reviewed'), keep('detail.note', 'firstNote'), keep('detail.reviewedAt', 'firstReviewedAt'),
      keep('detail.audio', 'firstAudio'), shot('reviewed-first'),
      'tap write-as', 'clock settle', shot('write-as-sheet'),
      `tap write-as-${other.id}`, 'clock settle', shot('template-picked'),
      'tap write-as-start', 'clock data', 'clock settle', check('detail.templateName', other.name), check('detail.patientRef', 'Bed 4'),
      check('detail.writtenFrom', first.name), check('detail.sharesRecording', true), same('detail.audio', 'firstAudio'), shot('second-writing'),
      'clock +12000', 'clock data', check('detail.state', 'draft'), check('detail.hasEdits', false), check('detail.reviewedAt', 0),
      ...other.sections.map((x) => has('detail.note', `## ${x.heading}`)), shot('second-draft'),
      check('lib.length', 2), check('lib.0.patientRef', 'Bed 4'), check('lib.1.patientRef', 'Bed 4'),
      'tap delete-note', 'clock settle', shot('confirm-delete-keeps-recording'),
      'tap delete-confirm', 'clock data', 'clock settle', check('lib.length', 1), check('lib.0.templateName', first.name),
      check('detail.templateName', first.name), check('detail.state', 'reviewed'), same('detail.note', 'firstNote'),
      same('detail.reviewedAt', 'firstReviewedAt'), same('detail.audio', 'firstAudio'), check('detail.sharesRecording', false),
      'tree player', shot('first-untouched-after-delete'),
      'back', 'clock data', 'clock settle', shot('one-note-left'),
    ],
    settings: [
      ...READY,
      'tap open-settings', 'clock data', 'clock settle', check('choice', tenant.defaults.tier), shot('settings'),
      'tap pick-lite', 'clock data', check('picked', 'lite'), check('setup.active', 'lite'), shot('lite-picked'),
      check('brand.privacy', tenant.copy.privacy),
    ],
  };
}

function run(slug, app, targetName, flowName, steps) {
  const target = TARGETS[targetName];
  const dir = join(ROOT, 'docs', 'media', 'clinic', slug, targetName, flowName);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });

  const ops = [];
  const checks = [];
  let shots = 0;
  for (const step of forHost(steps, target.host)) {
    if (typeof step === 'string') ops.push(withKeys(target.host, step));
    else if ('shot' in step) ops.push(`screenshot ${join(dir, `${String(++shots).padStart(2, '0')}-${step.shot}.png`)}`);
    else if (padOp(step, target.host)) {
      const { op, check: c, skip } = padOp(step, target.host);
      if (skip) { console.log(`  skipped: ${skip}`); continue; }
      checks.push({ at: ops.length, ...c });
      ops.push(op);
    } else {
      checks.push({ at: ops.length, ...step });
      ops.push(`state ${step.check}`);
    }
  }

  const storage = `flow-${flowName}-${Date.now()}`;
  const args = ['exact.mjs', 'agent', target.host, ...target.flags, '--storage', storage, '--reset-storage',
    '--permission', 'microphone=granted', '--json', ...ops];
  const started = Date.now();
  const result = spawnSync(BUN, args, { cwd: app, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const replies = result.stdout.split('\n').filter((l) => l.trim() !== '');
  const log = ops.map((op, i) => `${op}\n  ${replies[i] ?? '(no reply)'}`).join('\n');
  writeFileSync(join(dir, 'drive.log'), `${log.replaceAll(`${ROOT}/`, '').replaceAll(`${app}/`, '')}\n`);

  const failures = [];
  if (result.status !== 0) {
    const reason = result.stderr.split('\n').filter((l) => l.trim() !== '' && !l.startsWith('    at ') && !l.startsWith('exact:') && !l.startsWith('app:'));
    failures.push(`the drive exited ${result.status}: ${reason.slice(-2).join(' | ').slice(0, 400)}`);
  }
  const kept = {};
  for (const c of checks) {
    const raw = replies[c.at];
    let actual;
    try {
      actual = c.read ? c.read(raw) : JSON.parse(raw);
    } catch {
      actual = raw;
    }
    if ('keep' in c) {
      kept[c.keep] = actual;
    } else if ('same' in c) {
      if (JSON.stringify(actual) !== JSON.stringify(kept[c.same])) failures.push(`${c.check}: expected the ${c.same} kept earlier, ${JSON.stringify(kept[c.same])?.slice(0, 200)}, got ${(raw ?? '(no reply)').slice(0, 200)}`);
    } else if ('contains' in c) {
      if (typeof actual !== 'string' || !actual.includes(c.contains)) failures.push(`${c.check}: expected to contain ${JSON.stringify(c.contains)}, got ${(raw ?? '(no reply)').slice(0, 300)}`);
    } else if (JSON.stringify(actual) !== JSON.stringify(c.equals)) {
      failures.push(`${c.check}: expected ${JSON.stringify(c.equals)}, got ${c.read ? String(JSON.stringify(actual)).slice(0, 300) : (raw ?? '(no reply)').slice(0, 300)}`);
    }
  }

  const frames = readdirSync(dir).filter((f) => f.endsWith('.png')).sort();
  if (frames.length > 0) {
    const list = frames.map((f) => `file '${join(dir, f)}'\nduration 1.6`).join('\n');
    writeFileSync(join(dir, 'frames.txt'), `${list}\nfile '${join(dir, frames.at(-1))}'\n`);
    const video = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', join(dir, 'frames.txt'),
      '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p', '-r', '30', '-movflags', '+faststart', join(dir, `${flowName}.mp4`)],
      { encoding: 'utf8' });
    rmSync(join(dir, 'frames.txt'));
    if (video.status !== 0) failures.push(`ffmpeg: ${video.stderr.trim()}`);
  }
  return { flowName, frames: frames.length, checks: checks.length, failures, seconds: (Date.now() - started) / 1000 };
}

const [slug, app, targetName, ...only] = process.argv.slice(2);
const tenant = (await import(join(ROOT, 'tenants', `${slug}.ts`))).default;
const all = flows(tenant);
if (!TARGETS[targetName]) {
  console.error(`usage: bun tools/tenant.mjs flows <slug> <${Object.keys(TARGETS).join('|')}> [${Object.keys(all).join('|')}]…`);
  process.exit(2);
}
const names = only.length > 0 ? only : Object.keys(all);
const unknown = names.filter((n) => !all[n]);
if (unknown.length > 0) {
  console.error(`no such flow: ${unknown.join(', ')}`);
  process.exit(2);
}

let failed = 0;
for (const name of names) {
  const r = run(slug, app, targetName, name, all[name]);
  const verdict = r.failures.length === 0 ? 'ok' : 'FAIL';
  console.log(`${slug} ${targetName} ${name}: ${verdict} · ${r.checks} checks · ${r.frames} screenshots · ${r.seconds.toFixed(1)} s`);
  for (const f of r.failures) console.log(`  ${f}`);
  if (r.failures.length > 0) failed += 1;
}
console.log(`${names.length - failed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
