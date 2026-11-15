#!/usr/bin/env bun
// Runs the real pipeline in the built Android app with real models and a spoken
// fixture, then checks accuracy, structure, speed, and memory.
//
//   bun tools/e2e-android.mjs [lite|balanced] [--cycles 3]
//
// The agent's recorder writes a synthetic tone, so the script records a short
// take, replaces its audio file with tools/fixture/meeting-fixture.wav, and
// uses the app's "Transcribe again" button. Everything else is the app's own
// path: the Kotlin engine, the pipeline, the stored files.
//
// Results go to docs/media/android-real/e2e-<tier>.json. Exit code 0 means every
// check held.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const APP_ID = 'com.alona.app';
const FIXTURE = join(ROOT, 'tools', 'fixture', 'meeting-fixture.wav');
const REFERENCE = join(ROOT, 'tools', 'fixture', 'reference.txt');
const HEADINGS = ['## Summary', '## Key points', '## Decisions', '## Action items', '## Open questions'];
const WER_LIMIT = 0.15;

const args = process.argv.slice(2);
const tier = ['lite', 'balanced', 'quality'].find((t) => args.includes(t)) ?? 'lite';
const cycles = Math.max(3, Number(args[args.indexOf('--cycles') + 1]) || 3);
const storage = `e2e-${tier}`;
const out = join(ROOT, 'docs', 'media', 'android-real');
mkdirSync(out, { recursive: true });

/** Runs one agent drive. Returns each op's reply with the time it arrived. */
function drive(ops, { fresh = false, onReply = () => {} } = {}) {
  return new Promise((done, fail) => {
    const child = spawn(process.execPath, ['exact.mjs', 'agent', 'android', '--bind', 'engine', '--storage', storage,
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
        onReply(replies.length, replies.at(-1));
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

// PSS apportions shared pages among processes. It includes Java, native heaps and mapped models;
// it is not the amount of physical RAM exclusively owned by the app.
function appFootprintMB() {
  const result = spawnSync('adb', ['shell', 'dumpsys', 'meminfo', APP_ID], { encoding: 'utf8' });
  const match = result.stdout.match(/TOTAL PSS:\s*(\d+)/) ?? result.stdout.match(/^\s*TOTAL\s+(\d+)/m);
  return match ? Number(match[1]) / 1024 : 0;
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

try {
const build = spawnSync(process.execPath, ['exact.mjs', 'android'], { cwd: ROOT, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
if (build.status !== 0) throw new Error(build.stderr.slice(-4000));
const root = spawnSync('adb', ['root'], { encoding: 'utf8' });
if (root.stdout.includes('cannot run as root')) throw new Error('Use a google_apis emulator image, not google_apis_playstore.');
spawnSync('adb', ['wait-for-device']);
console.log(`e2e android ${tier}: preparing models`);
// The welcome screen offers "Not now" only while the recommended tier is not on this machine yet.
const welcome = await drive(['clock data', 'state setup.activeInstalled'], { fresh: true });
await drive(['clock data', value(welcome[1]) === true ? 'tap continue' : 'tap skip-download', 'clock data',
  'tap open-settings', 'clock data', `tap pick-${tier}`, 'clock data']);
const downloadStarted = Date.now();
let installed = value(welcome[1]) === true;
if (!installed) {
  const downloaded = await drive(['clock data', 'tap open-settings', 'clock data', `tap pick-${tier}`, 'clock data',
    `tap download-${tier}`, 'clock data', 'clock +1000 real', 'clock data', 'state setup.activeProgress',
    `screenshot ${join(out, 'download-progress.png')}`, 'clock +119000 real', 'clock data',
    'state setup.activeInstalled', 'state setup.activeError']);
  installed = value(downloaded.at(-2)) === true;
  need(installed, `models did not install: ${JSON.stringify(value(downloaded.at(-1)))}`);
  if (!installed) throw new Error(failures.join('; '));
}
const downloadSeconds = (Date.now() - downloadStarted) / 1000;

console.log('recording a take and swapping in the spoken fixture');
const recorded = await drive(['clock data', 'tap start-recording', 'clock data', 'clock settle', 'clock +3000', 'tap stop-recording',
  'clock data', 'clock settle', 'clock +20000 real', 'clock data', 'state detail.status', 'state detail.audio', 'state detail.title']);
const audio = value(recorded.at(-2));
const firstTitle = value(recorded.at(-1));
need(value(recorded.at(-3)) === 'done', `the tone recording ended as ${recorded.at(-3)?.raw}, expected done`);
const search = spawnSync('adb', ['shell', 'find', `/data/user/0/${APP_ID}`, '-path', `*/${storage}/data`], { encoding: 'utf8' });
const actualData = search.stdout.trim().split('\n').find((p) => p.endsWith(`/${storage}/data`));
if (!actualData) throw new Error('Cannot locate private agent data; use an emulator with adb root.');
const aac = '/tmp/alona-android-meeting-fixture.m4a';
const encoded = spawnSync('ffmpeg', ['-y', '-i', FIXTURE, '-c:a', 'aac', '-b:a', '96k', aac], { encoding: 'utf8' });
if (encoded.error) throw encoded.error;
if (encoded.status !== 0) throw new Error(encoded.stderr || 'ffmpeg could not encode the fixture.');
const pushed = spawnSync('adb', ['push', aac, `${actualData}/${String(audio).replace('app:/data/', '')}`], { encoding: 'utf8' });
if (pushed.status !== 0) throw new Error(pushed.stderr);
// adb root writes as root; restore the app's UID before it opens the fixture.
const owner = spawnSync('adb', ['shell', 'stat', '-c', '%u:%g', actualData], { encoding: 'utf8' }).stdout.trim();
spawnSync('adb', ['shell', 'chown', owner, `${actualData}/${String(audio).replace('app:/data/', '')}`]);

console.log(`running the pipeline ${cycles} times on the fixture`);
const POLLS = 600;
const ops = ['clock data', `tap "${firstTitle}"`, 'clock data', 'tap pane-transcript'];
const marks = [];
for (let c = 0; c < cycles; c++) {
  const signal = join(out, `.cycle-${c + 1}-done`);
  rmSync(signal, { force: true });
  marks.push({ cycle: c + 1, start: ops.length, signal });
  ops.push('tap retranscribe', 'clock data');
  for (let p = 0; p < POLLS; p++) ops.push(`clock +1000 real until ${signal}`, 'state detail.status');
  marks.at(-1).end = ops.length;
  ops.push('clock +30000 real');
  marks.at(-1).idle = ops.length;
}
const tail = ops.length;
ops.push('state detail.segments', 'state detail.aiNotes', 'state detail.title');

mkdirSync(out, { recursive: true });
const samples = [];
const sampler = setInterval(() => samples.push({ at: Date.now(), mb: appFootprintMB() }), 1000);
let replies;
try { replies = await drive(ops, { onReply: (count, reply) => {
  const mark = marks.find((m) => count > m.start && count <= m.end);
  if (mark && value(reply) === 'done') writeFileSync(mark.signal, 'done');
} }); } finally { clearInterval(sampler); }

clearInterval(sampler);
for (const mark of marks) rmSync(mark.signal, { force: true });

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

for (const run of runs) need(run.peakMB > 0 && Number.isFinite(run.idleMB) && run.idleMB > 0, `cycle ${run.cycle} has no valid PSS samples`);
for (const run of runs) need(run.finished, `cycle ${run.cycle} did not reach done within ${POLLS} s`);
need(wer.rate <= WER_LIMIT, `word error rate ${(wer.rate * 100).toFixed(1)}% is over ${WER_LIMIT * 100}%`);
for (const heading of HEADINGS) need(notes.includes(heading), `the notes lack "${heading}"`);
need(title !== '' && title !== 'Untitled meeting', 'the notes model proposed no title');
const idle = runs.map((r) => r.idleMB).filter(Number.isFinite);
if (idle.length >= 2) {
  need(idle.at(-1) <= idle[0] + 20, `idle memory grew from ${idle[0]} MB after cycle 1 to ${idle.at(-1)} MB after cycle ${idle.length}`);
}

const result = {
  host: 'android', tier, date: new Date().toISOString(),
  method: {
    audio: 'tools/fixture/meeting-fixture.wav (53 s synthetic three-speaker meeting), transcoded locally to AAC/M4A with ffmpeg, then copied over the recorded take',
    wer: 'lowercase, punctuation stripped, word-level edit distance, no number normalization',
    timing: 'wall time between agent replies polled once a second, so each figure is accurate to about one second',
    memory: 'dumpsys meminfo app-process PSS in MiB, sampled every 1000 ms; idle is the lowest sample in the 30 s that end a cycle, about a minute after the notes finish',
  },
  modelsPreviouslyInstalled: value(welcome[1]) === true,
  downloadSeconds: Math.round(downloadSeconds),
  wer: { ...wer, rate: Number(wer.rate.toFixed(4)) },
  title, transcript, notes, runs, failures,
};


// Best effort: a sleeping display or a locked screen gives no picture, and that must not cost the measurements.
await drive(['clock data', `tap "${title}"`, 'clock data', 'clock settle', `screenshot ${join(out, `notes-${tier}.png`)}`])
  .catch((e) => console.log(`no screenshot: ${e.message.split(':').slice(0, 2).join(':')}`));

writeFileSync(join(out, `e2e-${tier}.json`), `${JSON.stringify(result, null, 2)}\n`);

console.log(`word error rate (synthetic speech, easier than a real room): ${(wer.rate * 100).toFixed(1)}% (${wer.errors} of ${wer.words})`);
console.log(`title: ${title}`);
for (const r of runs) {
  console.log(`cycle ${r.cycle}: transcribe ${r.transcribeSeconds} s, notes ${r.notesSeconds} s, total ${r.totalSeconds} s, peak ${r.peakMB} MB, idle after ${r.idleMB} MB`);
}
for (const f of failures) console.log(`FAIL ${f}`);
console.log(failures.length === 0 ? 'e2e: ok' : `e2e: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);

} catch (error) {
  writeFileSync(join(out, `e2e-${tier}.json`), JSON.stringify({ host: 'android', tier, verdict: 'NOT VERIFIED', date: new Date().toISOString(), error: String(error) }, null, 2) + '\n');
  console.error(String(error));
  process.exit(1);
}
