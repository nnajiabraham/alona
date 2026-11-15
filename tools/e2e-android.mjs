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
import { mkdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

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
function appMemory() {
  const result = spawnSync('adb', ['shell', 'dumpsys', 'meminfo', APP_ID], { encoding: 'utf8' });
  const match = result.stdout.match(/TOTAL PSS:\s*(\d+)/) ?? result.stdout.match(/^\s*TOTAL\s+(\d+)/m);
  const heap = (name) => {
    const line = result.stdout.split('\n').find((line) => line.trimStart().startsWith(name + ' '));
    const values = line?.trim().split(/\s+/).slice(2).map(Number) ?? [];
    return { pss: Number.isFinite(values[0]) ? values[0] / 1024 : null, allocated: Number.isFinite(values[6]) ? values[6] / 1024 : null };
  };
  const native = heap('Native Heap'), java = heap('Dalvik Heap');
  return { mb: match ? Number(match[1]) / 1024 : 0, nativeAllocatedMB: native.allocated, javaAllocatedMB: java.allocated, nativePssMB: native.pss, javaPssMB: java.pss };
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
const welcome = await drive(['clock data', 'clock until state setup.demo == false within 120000', 'state setup.activeInstalled'], { fresh: true });
const selected = await drive(['clock data', value(welcome.at(-1)) === true ? 'tap continue' : 'tap skip-download', 'clock data',
  'tap open-settings', 'clock data', `tap pick-${tier}`, 'clock data', `clock until state setup.active == "${tier}" within 120000`, 'state setup.activeInstalled']);
const downloadStarted = Date.now();
let installed = value(selected.at(-1)) === true;
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
const fixtureDir = mkdtempSync(join(tmpdir(), 'alona-android-fixture-'));
const aac = join(fixtureDir, 'meeting-fixture.m4a');
const encoded = spawnSync('ffmpeg', ['-y', '-i', FIXTURE, '-ar', '48000', '-ac', '2', '-c:a', 'aac', '-b:a', '96k', aac], { encoding: 'utf8' });
if (encoded.error) throw encoded.error;
if (encoded.status !== 0) throw new Error(encoded.stderr || 'ffmpeg could not encode the fixture.');
const pushed = spawnSync('adb', ['push', aac, `${actualData}/${String(audio).replace('app:/data/', '')}`], { encoding: 'utf8' });
rmSync(fixtureDir, { recursive: true, force: true });
if (pushed.status !== 0) throw new Error(pushed.stderr);
// adb root writes as root; restore the app's UID before it opens the fixture.
const owner = spawnSync('adb', ['shell', 'stat', '-c', '%u:%g', actualData], { encoding: 'utf8' }).stdout.trim();
spawnSync('adb', ['shell', 'chown', owner, `${actualData}/${String(audio).replace('app:/data/', '')}`]);

console.log(`running the pipeline ${cycles} times on the fixture`);
const POLLS = 600;
const exactRoot = process.env.EXACT ?? '/Users/manlikeabro/Documents/repos/exact';
const { open } = await import(join(exactRoot, 'scripts/agent-session.mjs'));
const { stateOp } = await import(join(exactRoot, 'scripts/agent-inspect.mjs'));
const session = await open({ host: 'android', app: ROOT, reader: true, bind: 'engine', storage });
const read = (path) => stateOp(session, [path]);
const samples = [], runs = [];
let sampler;
let segments, notes, title;
try {
  await session.clock('data');
  await session.tap(firstTitle);
  await session.clock('data');
  await session.tap('pane-transcript');
  sampler = setInterval(() => samples.push({ at: Date.now(), ...appMemory() }), 1000);
  for (let c = 0; c < cycles; c++) {
    const started = Date.now();
    let summarizing, done, observedWork = false;
    await session.tap('retranscribe');
    for (let p = 0; p < POLLS; p++) {
      await session.clock('+1000 real');
      const status = await read('detail.status');
      if (['recorded', 'transcribing', 'summarizing'].includes(status)) observedWork = true;
      if (status === 'summarizing' && !summarizing) summarizing = Date.now();
      if (status === 'failed') throw new Error(`cycle ${c + 1}: ${await read('detail.error')}`);
      if (status === 'done' && observedWork) { done = Date.now(); break; }
    }
    if (!done) throw new Error(`cycle ${c + 1} timed out`);
    await session.clock('+30000 real');
    const idleTo = Date.now();
    const active = samples.filter((s) => s.at >= started && s.at <= done && s.mb > 0);
    const idle = samples.filter((s) => s.at >= idleTo - 10000 && s.at <= idleTo && s.mb > 0).sort((a, b) => a.mb - b.mb)[0];
    const run = {
      cycle: c + 1,
      transcribeSeconds: summarizing ? (summarizing - started) / 1000 : null,
      notesSeconds: summarizing ? (done - summarizing) / 1000 : null,
      totalSeconds: (done - started) / 1000,
      peakMB: Math.round(Math.max(0, ...active.map((s) => s.mb))),
      idleMB: idle ? Math.round(idle.mb) : null,
      idleNativeAllocatedMB: idle?.nativeAllocatedMB ?? null,
      idleJavaAllocatedMB: idle?.javaAllocatedMB ?? null,
      finished: true,
    };
    runs.push(run);
    console.log(`completed cycle ${run.cycle}: peak ${run.peakMB} MiB, idle ${run.idleMB} MiB, native allocated ${run.idleNativeAllocatedMB?.toFixed(1)} MiB`);
  }
  segments = await read('detail.segments');
  notes = String(await read('detail.aiNotes'));
  title = String(await read('detail.title'));
  await session.tap('pane-ai');
  await session.clock('settle');
  await session.screenshot(join(out, `notes-${tier}.png`));
} finally {
  clearInterval(sampler);
  await session.close();
}
const transcript = Array.isArray(segments) ? segments.map((s) => s.text).join(' ') : '';
const wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), transcript);

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
    audio: 'tools/fixture/meeting-fixture.wav (53 s synthetic three-speaker meeting), transcoded locally to 48 kHz stereo AAC/M4A with ffmpeg, then copied over the recorded take',
    wer: 'lowercase, punctuation stripped, word-level edit distance, no number normalization',
    timing: 'wall time between agent replies polled once a second, so each figure is accurate to about one second',
    memory: 'dumpsys meminfo app-process PSS in MiB, sampled every 1000 ms; idle is the lowest sample in the last 10 s of a 30 s idle window; adaptive polling stops at done, all cycles use one process; heap allocation columns are diagnostic, not PSS',
  },
  modelsPreviouslyInstalled: value(selected.at(-1)) === true,
  downloadSeconds: Math.round(downloadSeconds),
  wer: { ...wer, rate: Number(wer.rate.toFixed(4)) },
  title, transcript, notes, runs, samples, failures,
};


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
