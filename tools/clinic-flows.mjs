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

function flows(tenant) {
  const second = tenant.templates.find((t) => t.id !== tenant.defaults.template) ?? tenant.templates[0];
  const headings = second.sections.map((s) => `## ${s.heading}`);
  const READY = ['clock data', 'tap continue', 'clock data', 'clock +6000', 'clock data'];
  const RECORDED = [
    ...READY,
    'tap new-note-button', 'clock settle', 'type new-ref Bed 4', `tap template-${second.id}`, 'tap start-recording',
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
      'type new-ref Bed 4', `tap template-${second.id}`, shot('reference-and-template'),
      'tap start-recording', 'clock data', 'clock settle', check('rec.state', 'recording'), check('recRef', 'Bed 4'),
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
      'tap new-note-button', 'clock settle', 'tap start-recording', 'clock data', 'clock settle', 'clock +3000',
      check('rec.state', 'recording'), shot('recording'),
      'back', 'clock data', 'clock settle', check('recorderId', ''), check('trackId', ''), check('lib.length', 1), shot('back-stopped-and-saved'),
      'clock +12000', 'clock data', check('detail.state', 'draft'),
      'tap edit-note', 'clock settle', 'type note-editor ## Typed just before Back', 'back', 'clock data', 'clock +1500', 'clock data',
      check('lib.length', 1), shot('notes-after-back'),
      `tap "No ${tenant.copy.person.singular} reference"`, 'clock data', 'clock settle', check('detail.hasEdits', true),
      check('detail.note', '## Typed just before Back'), shot('edits-kept'),
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
  for (const step of steps) {
    if (typeof step === 'string') ops.push(step);
    else if ('shot' in step) ops.push(`screenshot ${join(dir, `${String(++shots).padStart(2, '0')}-${step.shot}.png`)}`);
    else {
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
  for (const c of checks) {
    const raw = replies[c.at];
    let actual;
    try {
      actual = JSON.parse(raw);
    } catch {
      actual = raw;
    }
    if ('contains' in c) {
      if (typeof actual !== 'string' || !actual.includes(c.contains)) failures.push(`${c.check}: expected to contain ${JSON.stringify(c.contains)}, got ${(raw ?? '(no reply)').slice(0, 300)}`);
    } else if (JSON.stringify(actual) !== JSON.stringify(c.equals)) {
      failures.push(`${c.check}: expected ${JSON.stringify(c.equals)}, got ${(raw ?? '(no reply)').slice(0, 300)}`);
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
