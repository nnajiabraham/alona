#!/usr/bin/env bun
// Drives each user flow through Exact's agent on one host, asserts what the
// app's state must be at each checkpoint, and keeps a screenshot per step
// plus a stepped video per flow under docs/media/<target>/<flow>/.
//
//   bun tools/flows.mjs web            every flow in a desktop-size browser
//   bun tools/flows.mjs web-phone      the same at a phone's size
//   bun tools/flows.mjs macos record   one flow on the macOS app
//
// The agent owns the clock, so the video is one frame per step, not a
// real-time capture. With the demo engine the transcript and notes are samples.
import { spawnSync } from 'node:child_process';
import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const BUN = process.execPath;
const APP_ID = 'com.alona.app';

const TARGETS = {
  web: { host: 'web', flags: ['--size', '1100x760'] },
  'web-phone': { host: 'web', flags: ['--size', '390x844'] },
  macos: { host: 'macos', flags: [], demoMarker: true },
  android: { host: 'android', flags: [] },
  ios: { host: 'ios', flags: [] },
};

const shot = (name) => ({ shot: name });
const check = (path, equals) => ({ check: path, equals });

const READY = ['clock data', 'tap continue', 'clock data', 'clock +6000', 'clock data'];
const RECORDED = [
  ...READY,
  'tap start-recording', 'clock data', 'clock settle',
  'type record-title Launch sync', 'type record-notes - Ask about the login fix',
  'clock +5000', 'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data',
];

const FLOWS = {
  onboarding: [
    'clock data', check('setup.ready', true), check('welcomed', false), shot('device-check'),
    'tap continue', 'clock data', check('welcomed', true), check('setup.activeDownloading', true), shot('downloading-models'),
    'clock +6000', 'clock data', check('setup.activeInstalled', true), shot('ready-to-record'),
  ],
  record: [
    ...READY,
    'tap start-recording', 'clock data', 'clock settle', check('rec.state', 'recording'), shot('recording-started'),
    'type record-title Launch sync', 'type record-notes - Ask about the login fix',
    'clock +5000', shot('notes-while-recording'),
    'tap stop-recording', 'clock data', 'clock settle', check('lib.0.status', 'recorded'), shot('saved-and-queued'),
    'clock +3000', 'clock data', check('lib.0.status', 'transcribing'), shot('transcribing'),
    'clock +2000', 'clock data', check('lib.0.status', 'summarizing'), shot('writing-notes'),
    'clock +6000', 'clock data', check('detail.status', 'done'), check('detail.title', 'Launch sync'),
    check('detail.userNotes', '- Ask about the login fix'), shot('notes-ready'),
  ],
  review: [
    ...RECORDED,
    check('detail.status', 'done'), shot('ai-notes'),
    'tap pane-transcript', check('pane', 'transcript'), shot('transcript'),
    'tap pane-mine', 'type my-notes ## Follow up', 'clock +1000', 'clock data',
    check('detail.userNotes', '## Follow up'), check('noteDirty', false), shot('my-notes-saved'),
    'type title-field Q1 launch plan', 'type title-field key Enter', 'clock data',
    check('detail.title', 'Q1 launch plan'), shot('renamed'),
    'tap pane-ai', 'tap regenerate', 'clock data', 'clock +1000', 'clock data', check('detail.status', 'summarizing'), shot('writing-again'),
    'clock +6000', 'clock data', check('detail.status', 'done'),
  ],
  library: [
    ...RECORDED,
    'back', 'clock data', check('lib.length', 1), shot('meetings'),
    'prefer prefers-color-scheme dark', shot('meetings-dark'), 'prefer prefers-color-scheme light',
    'tap "Launch sync"', 'clock data', 'tap delete-meeting', 'clock settle', shot('confirm-delete'),
    'tap delete-confirm', 'clock data', 'clock settle', check('lib.length', 0), shot('deleted'),
  ],
  settings: [
    ...READY,
    'tap open-settings', 'clock data', check('picked', 'auto'), check('setup.active', 'balanced'), shot('models'),
    'tap pick-lite', 'clock data', check('picked', 'lite'), check('setup.active', 'lite'),
    check('setup.activeInstalled', false), shot('lite-picked'),
    'tap download-lite', 'clock data', 'clock +6000', 'clock data', check('setup.activeInstalled', true), shot('lite-downloaded'),
    'tap remove-balanced', 'clock data', check('setup.tiers.1.installed', false), shot('balanced-removed'),
    'tap tier-auto', 'clock data', check('setup.active', 'balanced'), 'back', 'clock data', shot('needs-models-again'),
  ],
};

function run(targetName, flowName) {
  const target = TARGETS[targetName];
  const dir = join(ROOT, 'docs', 'media', targetName, flowName);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });

  const ops = [];
  const checks = [];
  let shots = 0;
  for (const step of FLOWS[flowName]) {
    if (typeof step === 'string') ops.push(step);
    else if ('shot' in step) ops.push(`screenshot ${join(dir, `${String(++shots).padStart(2, '0')}-${step.shot}.png`)}`);
    else {
      checks.push({ at: ops.length, ...step });
      ops.push(`state ${step.check}`);
    }
  }

  const storage = `flow-${flowName}-${Date.now()}`;
  const fresh = [];
  if (target.demoMarker) {
    // The Apple engine runs real models unless its data folder holds this file (modules/apple/Engine.swift).
    const data = join(homedir(), 'Library', 'Caches', 'exact', APP_ID, 'agent', storage, 'data');
    mkdirSync(data, { recursive: true });
    writeFileSync(join(data, 'demo-engine'), '');
  } else {
    fresh.push('--reset-storage');
  }
  const args = ['exact.mjs', 'agent', target.host, ...target.flags, '--storage', storage, ...fresh,
    '--permission', 'microphone=granted', '--json', ...ops];
  const result = spawnSync(BUN, args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const replies = result.stdout.split('\n').filter((l) => l.trim() !== '');
  const log = ops.map((op, i) => `${op}\n  ${replies[i] ?? '(no reply)'}`).join('\n');
  writeFileSync(join(dir, 'drive.log'), `${log.replaceAll(`${ROOT}/`, '')}\n`);

  const failures = [];
  if (result.status !== 0) failures.push(`the drive exited ${result.status}: ${result.stderr.trim().split('\n').slice(-3).join(' | ')}`);
  for (const c of checks) {
    const raw = replies[c.at];
    let actual;
    try {
      actual = JSON.parse(raw);
    } catch {
      actual = raw;
    }
    if (JSON.stringify(actual) !== JSON.stringify(c.equals)) {
      failures.push(`${c.check}: expected ${JSON.stringify(c.equals)}, got ${raw ?? '(no reply)'}`);
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
  return { flowName, frames: frames.length, checks: checks.length, failures };
}

const [targetName, ...only] = process.argv.slice(2);
if (!TARGETS[targetName]) {
  console.error(`usage: bun tools/flows.mjs <${Object.keys(TARGETS).join('|')}> [${Object.keys(FLOWS).join('|')}]…`);
  process.exit(2);
}
const names = only.length > 0 ? only : Object.keys(FLOWS);
const unknown = names.filter((n) => !FLOWS[n]);
if (unknown.length > 0) {
  console.error(`no such flow: ${unknown.join(', ')}`);
  process.exit(2);
}

let failed = 0;
for (const name of names) {
  const r = run(targetName, name);
  const verdict = r.failures.length === 0 ? 'ok' : 'FAIL';
  console.log(`${targetName} ${name}: ${verdict} · ${r.checks} checks · ${r.frames} screenshots`);
  for (const f of r.failures) console.log(`  ${f}`);
  if (r.failures.length > 0) failed += 1;
}
console.log(`${names.length - failed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
