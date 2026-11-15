#!/usr/bin/env bun
// Runs the real pipeline in the built macOS app with real models and a spoken
// fixture, then checks accuracy, structure, speed, and memory.
//
//   bun tools/e2e-native.mjs [lite|balanced|quality] [--cycles 3]
//   bun tools/e2e-native.mjs --long 10     memory over a 10-minute recording with system audio on
//
// The agent's recorder writes a synthetic tone, so the script records a short
// take, replaces its audio file with tools/fixture/meeting-fixture.wav, and
// uses the app's "Transcribe again" button. Everything else is the app's own
// path: the Swift engine, the pipeline, the stored files.
//
// Results go to docs/media/macos-real/e2e-<tier>.json. Exit code 0 means every
// check held.
import { dlopen, ptr } from 'bun:ffi';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const APP_ID = 'com.alona.app';
const FIXTURE = join(ROOT, 'tools', 'fixture', 'meeting-fixture.wav');
const REFERENCE = join(ROOT, 'tools', 'fixture', 'reference.txt');
const HEADINGS = ['## Summary', '## Key points', '## Decisions', '## Action items', '## Open questions'];
const WER_LIMIT = 0.15;

const args = process.argv.slice(2);
const tier = ['lite', 'balanced', 'quality'].find((t) => args.includes(t)) ?? 'lite';
const cycles = Number(args[args.indexOf('--cycles') + 1]) || 3;
const longMinutes = args.includes('--long') ? Number(args[args.indexOf('--long') + 1]) || 10 : 0;
const storage = longMinutes ? 'e2e-long' : `e2e-${tier}`;
const dataDir = join(homedir(), 'Library', 'Caches', 'exact', APP_ID, 'agent', storage, 'data');
const out = join(ROOT, 'docs', 'media', 'macos-real');

/** Runs one agent drive. Returns each op's reply with the time it arrived. */
function drive(ops, { fresh = false, onReply = () => {} } = {}) {
  return new Promise((done, fail) => {
    const child = spawn(process.execPath, ['exact.mjs', 'agent', 'macos', '--storage', storage,
      fresh ? '--reset-storage' : '--keep-storage', '--permission', 'microphone=granted', '--json', ...ops], { cwd: ROOT });
    const replies = [];
    let buffer = '', stderr = '';
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (line.trim() === '') continue;
        replies.push({ at: Date.now(), raw: line });
        onReply(replies.length);
      }
    });
    child.stderr.on('data', (chunk) => (stderr += chunk));
    child.on('close', (code) => {
      if (code === 0) return done(replies);
      const reason = stderr.split('\n').filter((line) => line.trim() !== '' && !line.startsWith('    at ') && !line.startsWith('exact:'));
      fail(new Error(`drive exited ${code} after ${replies.length} of ${ops.length} ops: ${reason.slice(-3).join(' | ')}`));
    });
  });
}

const value = (reply) => {
  try {
    return JSON.parse(reply.raw);
  } catch {
    return reply.raw;
  }
};

// Memory is the process's physical footprint, the figure Activity Monitor shows. Resident size is not
// used: it also counts freed pages the allocator keeps mapped until the system wants them back, which
// made an idle app look 900 MB large when its footprint was 103 MB.
const libproc = dlopen('libproc.dylib', { proc_pid_rusage: { args: ['i32', 'i32', 'ptr'], returns: 'i32' } });
const RUSAGE_INFO_V2 = 2, PHYS_FOOTPRINT_OFFSET = 72;

function appPid() {
  const found = spawnSync('pgrep', ['-f', `/${APP_ID}/macos/`], { encoding: 'utf8' }).stdout.trim().split('\n')[0];
  return found ? Number(found) : 0;
}

function appFootprintMB() {
  const pid = appPid();
  if (!pid) return 0;
  const info = new BigUint64Array(64);
  if (libproc.symbols.proc_pid_rusage(pid, RUSAGE_INFO_V2, ptr(info)) !== 0) return 0;
  return Number(new DataView(info.buffer).getBigUint64(PHYS_FOOTPRINT_OFFSET, true)) / 1048576;
}

const words = (text) => text.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter((w) => w !== '');

function wordErrorRate(reference, hypothesis) {
  const r = words(reference), h = words(hypothesis);
  let row = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    const next = [i];
    for (let j = 1; j <= h.length; j++) {
      next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
    }
    row = next;
  }
  return { errors: row[h.length], words: r.length, rate: row[h.length] / r.length };
}

const failures = [];
const need = (ok, message) => {
  if (!ok) failures.push(message);
};

if (longMinutes) {
  // The demo engine writes the notes: this measures the recording and the mix at its end, not the models.
  // Under the agent the microphone is Exact's synthetic tone and the system audio Alona's stand-in, so the
  // Core Audio tap itself is not running; the recorder, the stand-in's chunked writer and the mixer are.
  mkdirSync(dataDir, { recursive: true });
  writeFileSync(join(dataDir, 'demo-engine'), '');
  console.log(`e2e macos: recording for ${longMinutes} minutes, system audio ${args.includes('--mic-only') ? 'off' : 'on'}`);
  const ops = ['clock data', 'tap continue', 'clock data', 'clock +6000', 'clock data',
    'tap open-settings', 'clock data', 'clock settle', ...(args.includes('--mic-only') ? ['clock data'] : ['tap capture-switch']), 'clock data', 'state captureOn', 'back', 'clock data',
    'tap start-recording', 'clock data', 'clock settle', 'state rec.state'];
  const startAt = ops.length;
  for (let m = 0; m < longMinutes; m++) ops.push('clock +60000 real', 'state rec.state');
  const stopAt = ops.length;
  ops.push('tap stop-recording', 'clock data', 'clock settle');
  for (let p = 0; p < 90; p++) ops.push('clock +2000 real', 'state detail.status');
  ops.push('state detail.audio', 'state detail.title');
  const samples = [];
  const sampler = setInterval(() => samples.push({ at: Date.now(), mb: appFootprintMB() }), 500);
  const replies = await drive(ops, { fresh: true });
  clearInterval(sampler);
  const near = (at) => samples.filter((s) => s.mb > 0).reduce((best, s) => (Math.abs(s.at - at) < Math.abs(best.at - at) ? s : best), { at: 0, mb: 0 }).mb;
  const minutes = [];
  for (let m = 0; m <= longMinutes; m++) minutes.push(Math.round(near(replies[m === 0 ? startAt - 1 : startAt + m * 2 - 1].at)));
  const stopped = replies[stopAt].at;
  const after = samples.filter((s) => s.at >= stopped && s.mb > 0).map((s) => s.mb);
  const audio = String(value(replies.at(-2)));
  const statuses = replies.slice(stopAt + 3, -2).map(value);
  const file = join(dataDir, audio.replace('app:/data/', ''));
  const probe = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' });
  const seconds = Number(probe.stdout.trim());
  const micOnly = args.includes('--mic-only');
  need(value(replies[10]) === !micOnly, `system audio is ${value(replies[10])}`);
  need(micOnly || audio.endsWith('audio-mixed.m4a'), `the meeting kept ${audio}, not the mix`);
  need(Math.abs(seconds - longMinutes * 60) < 30, `the mix lasts ${seconds} s`);
  need(statuses.includes('done'), `the meeting ended as ${statuses.at(-1)}`);
  need(minutes.at(-1) <= minutes[1] + 50, `memory grew from ${minutes[1]} MB at minute 1 to ${minutes.at(-1)} MB at minute ${longMinutes}`);
  const result = {
    host: 'macos', date: new Date().toISOString(), minutes: longMinutes,
    method: 'physical footprint of the app process (proc_pid_rusage), sampled every 500 ms; one figure per minute of recording, and the peak from Stop until the meeting is done (the mix runs then)',
    footprintMBPerMinute: minutes, peakAfterStopMB: Math.round(Math.max(0, ...after)), mixSeconds: seconds, audio, failures,
  };
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, `long-recording-${longMinutes}min${args.includes('--mic-only') ? '-mic-only' : ''}.json`), `${JSON.stringify(result, null, 2)}\n`);
  console.log(`footprint by minute (MB): ${minutes.join(', ')}`);
  console.log(`peak from Stop to done: ${result.peakAfterStopMB} MB; mix ${seconds} s at ${audio}`);
  for (const f of failures) console.log(`FAIL ${f}`);
  console.log(failures.length === 0 ? 'long recording: ok' : `long recording: ${failures.length} failed`);
  process.exit(failures.length === 0 ? 0 : 1);
}

console.log(`e2e macos ${tier}: preparing models`);
// The welcome screen offers "Not now" only while the recommended tier is not on this machine yet.
const welcome = await drive(['clock data', 'state setup.activeInstalled'], { fresh: true });
await drive(['clock data', value(welcome[1]) === true ? 'tap continue' : 'tap skip-download', 'clock data',
  'tap open-settings', 'clock data', `tap pick-${tier}`, 'clock data']);
let installed = false;
const downloadStarted = Date.now();
for (let attempt = 0; attempt < 120 && !installed; attempt++) {
  const replies = await drive(['clock data', 'state setup.activeInstalled', 'state setup.activeDownloading', 'state setup.activeError']);
  installed = value(replies[1]) === true;
  if (installed) break;
  const error = value(replies[3]);
  if (error) throw new Error(`model download failed: ${error}`);
  if (value(replies[2]) !== true) await drive(['clock data', 'tap open-settings', 'clock data', `tap download-${tier}`, 'clock data', 'clock +15000 real', 'clock data']);
  else await drive(['clock data', 'clock +15000 real', 'clock data']);
}
need(installed, 'the tier never finished downloading');
const downloadSeconds = (Date.now() - downloadStarted) / 1000;

console.log('recording a take and swapping in the spoken fixture');
const recorded = await drive(['clock data', 'tap start-recording', 'clock data', 'clock settle', 'clock +3000', 'tap stop-recording',
  'clock data', 'clock settle', 'clock +20000 real', 'clock data', 'state detail.status', 'state detail.audio', 'state detail.title']);
const audio = value(recorded.at(-2));
const firstTitle = value(recorded.at(-1));
need(value(recorded.at(-3)) === 'done', `the tone recording ended as ${recorded.at(-3)?.raw}, expected done`);
copyFileSync(FIXTURE, join(dataDir, String(audio).replace('app:/data/', '')));

console.log(`running the pipeline ${cycles} times on the fixture`);
const POLLS = tier === 'quality' ? 180 : 60;
const ops = ['clock data', `tap "${firstTitle}"`, 'clock data', 'tap pane-transcript'];
const marks = [];
for (let c = 0; c < cycles; c++) {
  marks.push({ cycle: c + 1, start: ops.length });
  ops.push('tap retranscribe', 'clock data');
  for (let p = 0; p < POLLS; p++) ops.push('clock +1000 real', 'state detail.status');
  marks.at(-1).end = ops.length;
  ops.push('clock +3000 real');
  marks.at(-1).idle = ops.length;
}
const tail = ops.length;
ops.push('state detail.segments', 'state detail.aiNotes', 'state detail.title');

mkdirSync(out, { recursive: true });
const samples = [];
const sampler = setInterval(() => samples.push({ at: Date.now(), mb: appFootprintMB() }), 250);
// With VMMAP_OUT set, a memory map of the app is written while it idles after the last cycle.
const mapAt = marks.at(-1).idle - 1;
const replies = await drive(ops, {
  onReply: (count) => {
    if (count !== mapAt || !process.env.VMMAP_OUT) return;
    spawn('sh', ['-c', `vmmap --summary ${appPid()} > '${process.env.VMMAP_OUT}' 2>&1`]);
  },
});
clearInterval(sampler);

const segments = value(replies[tail]);
const notes = String(value(replies[tail + 1]));
const title = String(value(replies[tail + 2]));
const transcript = Array.isArray(segments) ? segments.map((s) => s.text).join(' ') : '';
const wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), transcript);

const between = (from, to) => samples.filter((s) => s.at >= from && s.at <= to && s.mb > 0).map((s) => s.mb);
const runs = marks.map((m) => {
  const started = replies[m.start].at;
  const statuses = [];
  for (let i = m.start + 3; i < m.end; i += 2) statuses.push({ at: replies[i].at, status: value(replies[i]) });
  const first = (status) => statuses.find((s) => s.status === status)?.at;
  const done = first('done'), summarizing = first('summarizing');
  const idleFrom = replies[m.end - 1].at, idleTo = replies[m.idle - 1].at;
  return {
    cycle: m.cycle,
    transcribeSeconds: summarizing ? (summarizing - started) / 1000 : null,
    notesSeconds: done && summarizing ? (done - summarizing) / 1000 : null,
    totalSeconds: done ? (done - started) / 1000 : null,
    peakMB: Math.round(Math.max(0, ...between(started, done ?? idleTo))),
    idleMB: Math.round(Math.min(...between(idleFrom, idleTo), Infinity)),
    finished: Boolean(done),
  };
});

for (const run of runs) need(run.finished, `cycle ${run.cycle} did not reach done within ${POLLS} s`);
need(wer.rate <= WER_LIMIT, `word error rate ${(wer.rate * 100).toFixed(1)}% is over ${WER_LIMIT * 100}%`);
for (const heading of HEADINGS) need(notes.includes(heading), `the notes lack "${heading}"`);
need(title !== '' && title !== 'Untitled meeting', 'the notes model proposed no title');
const idle = runs.map((r) => r.idleMB).filter(Number.isFinite);
if (idle.length >= 2) {
  need(idle.at(-1) <= idle[0] * 1.25 + 100, `idle memory grew from ${idle[0]} MB after cycle 1 to ${idle.at(-1)} MB after cycle ${idle.length}`);
}

const result = {
  host: 'macos', tier, date: new Date().toISOString(),
  method: {
    audio: 'tools/fixture/meeting-fixture.wav (53 s synthetic three-speaker meeting), copied over the recorded take',
    wer: 'lowercase, punctuation stripped, word-level edit distance, no number normalization',
    timing: 'wall time between agent replies polled once a second, so each figure is accurate to about one second',
    memory: 'physical footprint of the app process (proc_pid_rusage), sampled every 250 ms; idle is the lowest sample in the 3 s that end a cycle, about a minute after the notes finish',
  },
  downloadSeconds: Math.round(downloadSeconds),
  wer: { ...wer, rate: Number(wer.rate.toFixed(4)) },
  title, transcript, notes, runs, failures,
};
writeFileSync(join(out, `e2e-${tier}.json`), `${JSON.stringify(result, null, 2)}\n`);

// Best effort: a sleeping display or a locked screen gives no picture, and that must not cost the measurements.
await drive(['clock data', `tap "${title}"`, 'clock data', `screenshot ${join(out, `notes-${tier}.png`)}`])
  .catch((e) => console.log(`no screenshot: ${e.message.split(':').slice(0, 2).join(':')}`));

console.log(`word error rate: ${(wer.rate * 100).toFixed(1)}% (${wer.errors} of ${wer.words})`);
console.log(`title: ${title}`);
for (const r of runs) {
  console.log(`cycle ${r.cycle}: transcribe ${r.transcribeSeconds} s, notes ${r.notesSeconds} s, total ${r.totalSeconds} s, peak ${r.peakMB} MB, idle after ${r.idleMB} MB`);
}
for (const f of failures) console.log(`FAIL ${f}`);
console.log(failures.length === 0 ? 'e2e: ok' : `e2e: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
