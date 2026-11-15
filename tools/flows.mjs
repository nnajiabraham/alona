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
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { check, formatSteps, padClean, padOp, pressed, shot, withKeys } from './pad-steps.mjs';

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
    'back', 'clock data', 'clock settle', check('lib.length', 1), shot('meetings'),
    'prefer prefers-color-scheme dark', shot('meetings-dark'), 'prefer prefers-color-scheme light',
    'tap "Launch sync"', 'clock data', 'clock settle', 'tap delete-meeting', 'clock settle', shot('confirm-delete'),
    'tap delete-confirm', 'clock data', 'clock settle', check('lib.length', 0), shot('deleted'),
  ],
  // Leaving a screen by the platform's Back runs no action of the app's, so these two paths need their own proof.
  leaving: [
    ...READY,
    'tap start-recording', 'clock data', 'clock settle', 'clock +3000', check('rec.state', 'recording'), shot('recording'),
    'back', 'clock data', 'clock settle', check('recorderId', ''), check('trackId', ''), check('lib.length', 1), shot('back-stopped-and-saved'),
    'clock +12000', 'clock data', check('detail.status', 'done'),
    'tap pane-mine', 'type my-notes ## Typed just before Back', 'back', 'clock data', 'clock +1500', 'clock data',
    check('lib.length', 1), shot('library-after-back'),
    'tap "Sample notes"', 'clock data', 'clock settle', check('detail.userNotes', '## Typed just before Back'),
    'tap pane-mine', shot('notes-kept'),
  ],
  settings: [
    ...READY,
    'tap open-settings', 'clock data', 'clock settle', check('picked', 'auto'), check('setup.active', 'balanced'), shot('models'),
    'tap pick-lite', 'clock data', check('picked', 'lite'), check('setup.active', 'lite'),
    check('setup.activeInstalled', false), shot('lite-picked'),
    'tap download-lite', 'clock data', 'clock +6000', 'clock data', check('setup.activeInstalled', true), shot('lite-downloaded'),
    'tap remove-balanced', 'clock data', check('setup.tiers.1.installed', false), shot('balanced-removed'),
    'tap tier-auto', 'clock data', check('setup.active', 'balanced'), 'back', 'clock data', shot('needs-models-again'),
  ],
  // Each step types a fresh value (an agent `type` replaces the field and leaves the caret at its end),
  // selects it where the command works on a selection, presses one button and reads the stored Markdown.
  // The pads at the largest text size iOS offers (a 53 px root at a phone's width), each scrolled into view.
  'toolbar-large': [
    ...READY, 'prefer root-font-size 53px', 'tap start-recording', 'clock data', 'clock settle',
    'type record-notes - Agenda', 'tap rec-bold', 'clock settle', padClean('rec', 'record-notes'), shot('record-pad-large'),
    'prefer prefers-color-scheme dark', 'clock settle', shot('record-pad-large-dark'), 'prefer prefers-color-scheme light',
    'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data',
    'tap pane-mine', 'clock settle', 'tap mine-link', 'clock settle', padClean('mine', 'my-notes'), shot('my-notes-large'),
    'prefer prefers-color-scheme dark', 'clock settle', shot('my-notes-large-dark'),
  ],
  toolbar: [
    ...READY,
    'tap start-recording', 'clock data', 'clock settle', shot('empty-pad'),
    ...formatSteps('rec', 'record-notes', 'recNotes'),
    'type record-notes Agenda', 'clock +5000', 'clock data', 'tap rec-stamp', 'clock data', check('recNotes', 'Agenda[0:05] '), shot('timestamp'),
    'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data', check('detail.status', 'done'),
    'tap pane-mine', 'clock settle', 'type my-notes Decisions', 'tap mine-title', 'clock data', check('noteDraft', '## Decisions'),
    pressed('mine-title', true), 'tap mine-plain', 'clock data', check('noteDraft', 'Decisions'),
    'tap mine-ordered', 'clock data', check('noteDraft', '1. Decisions'), pressed('mine-ordered', true), shot('my-notes-numbered'),
    'clock +1500', 'clock data', check('detail.userNotes', '1. Decisions'),
  ],
};

/** A mono 16-bit WAV of a tone, the stand-in for a Swift-app recording. */
function wav(seconds, hz) {
  const rate = 16000, n = rate * seconds, out = Buffer.alloc(44 + n * 2);
  out.write('RIFF', 0); out.writeUInt32LE(36 + n * 2, 4); out.write('WAVEfmt ', 8); out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22); out.writeUInt32LE(rate, 24); out.writeUInt32LE(rate * 2, 28);
  out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34); out.write('data', 36); out.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) out.writeInt16LE(Math.round(8000 * Math.sin((2 * Math.PI * hz * i) / rate)), 44 + i * 2);
  return out;
}

/** Every file under `dir` with its SHA-256, to prove a flow left a folder as it found it. */
function digest(dir) {
  const out = {};
  const walk = (d) => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else out[p.slice(dir.length + 1)] = createHash('sha256').update(readFileSync(p)).digest('hex');
    }
  };
  walk(dir);
  return out;
}

const meetingDirs = (root) => (existsSync(root) ? readdirSync(root).filter((n) => !n.startsWith('.') && !n.endsWith('.moving')) : []);

// Flows that need the macOS module: a folder outside app storage, the Swift app's
// recordings, detection and system audio. Each prepares its data folder or a
// fixture folder before the drive, and checks the files the drive left after it.
const MAC_FLOWS = {
  menubar: {
    steps: [
      ...READY, check('statusItems.0.testId', 'status-item'), check('statusItems.0.menu.0.label', 'Ready to record'), shot('ready'),
      'close', 'clock data', check('statusItems.0.menu.1.label', 'Start recording'),
      'tap status-item', 'clock settle', 'tap status-start', 'clock data', 'clock settle', 'clock +4000', 'clock data',
      check('rec.state', 'recording'), check('statusLine', 'Recording · 0:04'), check('statusItems.0.menu.1.label', 'Stop recording'),
      'tap status-item', 'clock settle', 'tap status-stop', 'clock data', 'clock settle', 'clock +3000', 'clock data',
      check('lib.length', 1), check('statusLine', 'Writing notes…'),
      'tap status-item', 'clock settle', 'tap status-open', 'clock data', 'clock settle', shot('opened-from-menu-bar'),
      'clock +12000', 'clock data', check('statusLine', 'Ready to record'), check('lib.0.status', 'done'), shot('done-while-hidden'),
    ],
  },
  folder: {
    setup: (ctx) => {
      ctx.vars.folder = join(ctx.tmp, 'Meetings');
      mkdirSync(ctx.vars.folder, { recursive: true });
      ctx.vars.real = realpathSync(ctx.vars.folder);
    },
    steps: [
      ...RECORDED, 'back', 'clock data', 'clock settle',
      'tap open-settings', 'clock data', 'clock settle', check('desk.foldersSupported', true), check('desk.folder', ''), shot('app-storage'),
      'tap choose-folder', 'clock settle', 'type @folder-picker {folder}', 'clock data', 'clock settle', 'clock +2000', 'clock data',
      check('desk.folder', '{real}'), check('desk.folderReachable', true), check('desk.waiting', 0), shot('folder-chosen'),
      'back', 'clock data', 'clock settle', check('lib.length', 1), 'tap "Launch sync"', 'clock data', 'clock settle',
      check('detail.status', 'done'), check('detail.userNotes', '- Ask about the login fix'), shot('meeting-from-folder'),
      'tap pane-mine', 'type my-notes - Edited in the folder', 'clock +1000', 'clock data', check('detail.userNotes', '- Edited in the folder'),
    ],
    after: (ctx) => {
      const there = meetingDirs(ctx.vars.real);
      const here = meetingDirs(join(ctx.data, 'meetings'));
      const failures = [];
      if (there.length !== 1) failures.push(`the folder holds ${there.length} meetings, not 1`);
      else {
        const files = readdirSync(join(ctx.vars.real, there[0]));
        for (const f of ['meeting.json', 'notes.md']) if (!files.includes(f)) failures.push(`the moved meeting has no ${f}: ${files.join(', ')}`);
        if (!files.some((f) => f.startsWith('audio'))) failures.push(`the moved meeting has no audio: ${files.join(', ')}`);
        const notes = readFileSync(join(ctx.vars.real, there[0], 'notes.md'), 'utf8');
        if (!notes.includes('Edited in the folder')) failures.push(`the edit did not reach the folder: ${notes}`);
      }
      if (here.length !== 0) failures.push(`app storage still holds ${here.join(', ')}`);
      return failures;
    },
  },
  'folder-missing': {
    setup: (ctx) => writeFileSync(join(ctx.data, 'library.json'), JSON.stringify({ folder: join(ctx.tmp, 'Unplugged', 'Meetings') })),
    steps: [
      ...RECORDED, check('detail.status', 'done'), 'back', 'clock data', 'clock settle', check('lib.length', 1), shot('meetings-still-listed'),
      'tap open-settings', 'clock data', 'clock settle', check('desk.folderReachable', false), check('desk.waiting', 1), shot('folder-missing'),
    ],
  },
  migration: {
    setup: (ctx) => {
      const swift = (ctx.vars.swift = join(ctx.tmp, 'Swift Alona'));
      const put = (dir, files) => {
        mkdirSync(join(swift, dir), { recursive: true });
        for (const [name, body] of Object.entries(files)) writeFileSync(join(swift, dir, name), body);
      };
      put('2025-11-27_1030_Product-Sync', {
        'title.txt': 'Product sync\n', 'recording.wav': wav(3, 300), 'notes.md': '- Ask about pricing',
        'transcript.json': JSON.stringify([{ start: 0, end: 2.5, text: 'Hello all, this is the product sync.' }]), 'summary.md': '# Summary\n\n(placeholder)',
      });
      put('2025-11-28_0900_Crash', { 'recording-mono.wav': wav(2, 500), 'notes.tmp': 'Draft before the crash' });
      put('.DS_Store-like', { 'x': 'not a meeting' });
      ctx.vars.before = digest(swift);
    },
    steps: [
      ...READY, 'tap open-settings', 'clock data', 'clock settle', check('desk.legacyLooked', false), shot('not-looked-yet'),
      'tap pick-legacy', 'clock settle', 'type @legacy-picker {swift}', 'clock data', 'clock settle',
      check('desk.legacyLooked', true), check('desk.legacyCount', 2), check('desk.legacyNew', 2), shot('found'),
      'tap import-legacy', 'clock data', 'clock settle', 'clock +1000', 'clock data', check('desk.legacyNew', 0), shot('imported'),
      'back', 'clock data', 'clock settle', 'clock +12000', 'clock data', check('lib.length', 2),
      check('lib.0.title', 'Crash'), check('lib.1.title', 'Product sync'), shot('library'),
      'tap "Product sync"', 'clock data', 'clock settle', check('detail.status', 'done'), check('detail.userNotes', '- Ask about pricing'),
      'tap pane-transcript', 'clock settle', shot('transcript'),
      'tap pane-ai', 'clock settle', 'tap write-notes', 'clock data', 'clock +6000', 'clock data', check('detail.status', 'done'), shot('notes-written'),
    ],
    after: (ctx) => {
      const now = digest(ctx.vars.swift);
      return JSON.stringify(now) === JSON.stringify(ctx.vars.before) ? [] : ['the Swift folder changed during the import'];
    },
  },
  detection: {
    setup: (ctx) => writeFileSync(join(ctx.data, 'detect-fixture.json'), JSON.stringify({ app: 'zoom', title: 'Weekly design review' })),
    steps: [
      ...READY, check('meet.found', true), check('offerMeeting', true), shot('call-detected'),
      'tap detected-record', 'clock data', 'clock settle', check('rec.state', 'recording'), check('recTitle', 'Weekly design review'), shot('recording-the-call'),
      'clock +4000', 'tap stop-recording', 'clock data', 'clock settle', 'back', 'clock data', 'clock settle', check('offerMeeting', false), shot('offer-gone'),
      'tap open-settings', 'clock data', 'clock settle', check('desk.detectionSupported', true), shot('detection-settings'),
      'tap detect-switch', 'clock data', 'clock settle', check('detectOn', false), check('meet.found', false), shot('detection-off'),
    ],
  },
  'system-audio': {
    steps: [
      ...READY, 'tap open-settings', 'clock data', 'clock settle', check('desk.captureSupported', true), check('captureOn', false), shot('off'),
      'tap capture-switch', 'clock data', 'clock settle', check('captureOn', true), shot('on'), 'back', 'clock data', 'clock settle',
      'tap start-recording', 'clock data', 'clock settle', check('rec.state', 'recording'), 'clock +6000', 'clock data',
      'tap stop-recording', 'clock data', 'clock settle', 'clock +12000', 'clock data', check('detail.status', 'done'), shot('mixed-meeting'),
      'back', 'clock data', 'tap open-settings', 'clock data', 'clock settle', check('desk.captureHealth', 'heard'), shot('heard'),
    ],
    after: (ctx) => {
      const [id] = meetingDirs(join(ctx.data, 'meetings'));
      if (!id) return ['no meeting was saved'];
      const dir = join(ctx.data, 'meetings', id);
      const files = readdirSync(dir);
      const failures = [];
      for (const f of ['system.m4a', 'audio-mixed.m4a']) if (!files.includes(f)) failures.push(`no ${f}: ${files.join(', ')}`);
      if (failures.length > 0) return failures;
      const meeting = JSON.parse(readFileSync(join(dir, 'meeting.json'), 'utf8'));
      if (!String(meeting.audio).endsWith('audio-mixed.m4a')) failures.push(`the meeting keeps ${meeting.audio}`);
      // The stand-in system audio is a 1500 Hz tone and the agent's microphone a 440 Hz one. Both must be in the mix.
      const level = (file, filter) => {
        const r = spawnSync('ffmpeg', ['-hide_banner', '-i', join(dir, file), '-af', `${filter},volumedetect`, '-f', 'null', '-'], { encoding: 'utf8' });
        return Number(/mean_volume: (-?[\d.]+) dB/.exec(r.stderr)?.[1] ?? -999);
      };
      const mic = files.find((f) => f.startsWith('audio') && f !== 'audio-mixed.m4a');
      const band = (file, hz) => level(file, `bandpass=f=${hz}:w=60,bandpass=f=${hz}:w=60`);
      const at = { mixed440: band('audio-mixed.m4a', 440), mixed1500: band('audio-mixed.m4a', 1500), mic440: mic ? band(mic, 440) : -999, mic1500: mic ? band(mic, 1500) : -999, system1500: band('system.m4a', 1500) };
      ctx.notes.push(`band levels (dB): ${JSON.stringify(at)}`);
      if (at.mixed1500 < at.mic1500 + 20) failures.push('the system audio is not in the mix');
      if (at.mixed440 < at.mic440 - 3) failures.push('the microphone is not in the mix');
      return failures;
    },
  },
};

function run(targetName, flowName) {
  const target = TARGETS[targetName];
  const dir = join(ROOT, 'docs', 'media', targetName, flowName);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });

  const flow = Array.isArray(FLOWS[flowName]) ? { steps: FLOWS[flowName] } : FLOWS[flowName];
  const storage = `flow-${flowName}-${Date.now()}`;
  const data = join(homedir(), 'Library', 'Caches', 'exact', APP_ID, 'agent', storage, 'data');
  const ctx = { data, tmp: join(tmpdir(), 'alona-flows', storage), vars: {}, notes: [] };
  if (flow.setup) {
    mkdirSync(data, { recursive: true });
    mkdirSync(ctx.tmp, { recursive: true });
    flow.setup(ctx);
  }
  const fill = (text) => text.replace(/\{(\w+)\}/g, (_, k) => ctx.vars[k] ?? `{${k}}`);

  const ops = [];
  const checks = [];
  let shots = 0;
  for (const step of flow.steps) {
    if (typeof step === 'string') ops.push(withKeys(target.host, fill(step)));
    else if ('shot' in step) ops.push(`screenshot ${join(dir, `${String(++shots).padStart(2, '0')}-${step.shot}.png`)}`);
    else if (padOp(step)) {
      const { op, check: c } = padOp(step);
      checks.push({ at: ops.length, ...c });
      ops.push(op);
    } else {
      checks.push({ at: ops.length, check: step.check, equals: typeof step.equals === 'string' ? fill(step.equals) : step.equals });
      ops.push(`state ${step.check}`);
    }
  }

  const fresh = [];
  if (target.demoMarker) {
    // The Apple engine runs real models unless its data folder holds this file (modules/apple/Engine.swift).
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
  if (result.status !== 0) {
    const reason = result.stderr.split('\n').filter((l) => l.trim() !== '' && !l.startsWith('    at ') && !l.startsWith('exact:') && !l.startsWith('app:'));
    failures.push(`the drive exited ${result.status}: ${reason.slice(-2).join(' | ').slice(0, 400)}`);
  }
  for (const c of checks) {
    const raw = replies[c.at];
    let actual;
    try {
      actual = c.read ? c.read(raw) : JSON.parse(raw);
    } catch {
      actual = raw;
    }
    if (JSON.stringify(actual) !== JSON.stringify(c.equals)) {
      failures.push(`${c.check}: expected ${JSON.stringify(c.equals)}, got ${c.read && actual !== raw ? JSON.stringify(actual) : (raw ?? '(no reply)').slice(0, 300)}`);
    }
  }

  if (flow.after && result.status === 0) failures.push(...flow.after(ctx));
  if (ctx.notes.length > 0) writeFileSync(join(dir, 'files.log'), `${ctx.notes.join('\n')}\n`);

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
  return { flowName, frames: frames.length, checks: checks.length, failures, notes: ctx.notes };
}

const [targetName, ...only] = process.argv.slice(2);
if (TARGETS[targetName]?.host === 'macos') Object.assign(FLOWS, MAC_FLOWS);
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
  for (const n of r.notes) console.log(`  ${n}`);
  for (const f of r.failures) console.log(`  ${f}`);
  if (r.failures.length > 0) failed += 1;
}
console.log(`${names.length - failed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
