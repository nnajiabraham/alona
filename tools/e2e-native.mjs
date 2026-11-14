#!/usr/bin/env bun
// Runs the real pipeline in the built macOS app with real models and a spoken
// fixture, then checks accuracy, structure, speed, and memory.
//
//   bun tools/e2e-native.mjs [lite|balanced|quality] [--cycles 3]
//
// The agent's recorder writes a synthetic tone, so the script records a short
// take, replaces its audio file with tools/fixture/meeting-fixture.wav, and
// uses the app's "Transcribe again" button. Everything else is the app's own
// path: the Swift engine, the pipeline, the stored files.
//
// Results go to docs/media/macos-real/e2e-<tier>.json. Exit code 0 means every
// check held.
import { spawn } from 'node:child_process';
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
const storage = `e2e-${tier}`;
const dataDir = join(homedir(), 'Library', 'Caches', 'exact', APP_ID, 'agent', storage, 'data');
const out = join(ROOT, 'docs', 'media', 'macos-real');

/** Runs one agent drive. Returns each op's reply with the time it arrived. */
function drive(ops, { fresh = false } = {}) {
  return new Promise((done, fail) => {
    const child = spawn(process.execPath, ['exact.mjs', 'agent', 'macos', '--storage', storage,
      fresh ? '--reset-storage' : '--keep-storage', '--permission', 'microphone=granted', '--json', ...ops], { cwd: ROOT });
    const replies = [];
    let buffer = '', stderr = '';
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) if (line.trim() !== '') replies.push({ at: Date.now(), raw: line });
    });
    child.stderr.on('data', (chunk) => (stderr += chunk));
    child.on('close', (code) => (code === 0 ? done(replies) : fail(new Error(`drive exited ${code}: ${stderr.trim().split('\n').slice(-4).join(' | ')}`))));
  });
}

const value = (reply) => {
  try {
    return JSON.parse(reply.raw);
  } catch {
    return reply.raw;
  }
};

function appRssMB() {
  return new Promise((done) => {
    const ps = spawn('sh', ['-c', `ps -axo rss=,command= | grep '/${APP_ID}/macos/' | grep -v grep | awk '{s+=$1} END {print s+0}'`]);
    let text = '';
    ps.stdout.on('data', (chunk) => (text += chunk));
    ps.on('close', () => done(Number(text.trim()) / 1024));
  });
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

console.log(`e2e macos ${tier}: preparing models`);
await drive(['clock data', 'tap skip-download', 'clock data', 'tap open-settings', 'clock data', `tap pick-${tier}`, 'clock data',
  `state setup.activeInstalled`], { fresh: true });
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
ops.push('state detail.segments', 'state detail.aiNotes', 'state detail.title', 'tap pane-ai', `screenshot ${join(out, `notes-${tier}.png`)} window`);

mkdirSync(out, { recursive: true });
const samples = [];
const sampler = setInterval(async () => samples.push({ at: Date.now(), mb: await appRssMB() }), 250);
const replies = await drive(ops);
clearInterval(sampler);

const segments = value(replies[tail]);
const notes = String(value(replies[tail + 1]));
const title = String(value(replies[tail + 2]));
const transcript = Array.isArray(segments) ? segments.map((s) => s.text).join(' ') : '';
const wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), transcript);

const between = (from, to) => samples.filter((s) => s.at >= from && s.at <= to).map((s) => s.mb);
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
    peakRssMB: Math.round(Math.max(0, ...between(started, done ?? idleTo))),
    idleRssMB: Math.round(Math.min(...between(idleFrom, idleTo), Infinity)),
    finished: Boolean(done),
  };
});

for (const run of runs) need(run.finished, `cycle ${run.cycle} did not reach done within ${POLLS} s`);
need(wer.rate <= WER_LIMIT, `word error rate ${(wer.rate * 100).toFixed(1)}% is over ${WER_LIMIT * 100}%`);
for (const heading of HEADINGS) need(notes.includes(heading), `the notes lack "${heading}"`);
need(title !== '' && title !== 'Untitled meeting', 'the notes model proposed no title');
const idle = runs.map((r) => r.idleRssMB).filter(Number.isFinite);
if (idle.length >= 2) {
  need(idle.at(-1) <= idle[0] * 1.25 + 100, `idle memory grew from ${idle[0]} MB after cycle 1 to ${idle.at(-1)} MB after cycle ${idle.length}`);
}

const result = {
  host: 'macos', tier, date: new Date().toISOString(),
  method: {
    audio: 'tools/fixture/meeting-fixture.wav (53 s synthetic three-speaker meeting), copied over the recorded take',
    wer: 'lowercase, punctuation stripped, word-level edit distance, no number normalization',
    timing: 'wall time between agent replies polled once a second, so each figure is accurate to about one second',
    memory: 'ps resident set size of the app process, sampled every 250 ms; idle is the lowest sample in the 3 s after a cycle',
  },
  downloadSeconds: Math.round(downloadSeconds),
  wer: { ...wer, rate: Number(wer.rate.toFixed(4)) },
  title, transcript, notes, runs, failures,
};
writeFileSync(join(out, `e2e-${tier}.json`), `${JSON.stringify(result, null, 2)}\n`);

console.log(`word error rate: ${(wer.rate * 100).toFixed(1)}% (${wer.errors} of ${wer.words})`);
console.log(`title: ${title}`);
for (const r of runs) {
  console.log(`cycle ${r.cycle}: transcribe ${r.transcribeSeconds} s, notes ${r.notesSeconds} s, total ${r.totalSeconds} s, peak ${r.peakRssMB} MB, idle after ${r.idleRssMB} MB`);
}
for (const f of failures) console.log(`FAIL ${f}`);
console.log(failures.length === 0 ? 'e2e: ok' : `e2e: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
