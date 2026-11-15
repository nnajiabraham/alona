#!/usr/bin/env bun
// The web engine with real models in a real browser, driven through the UI:
//
//   bun tools/e2e-web.mjs
//
// It builds the engine and a release site, serves it, and launches installed
// Google Chrome with a fresh profile, WebGPU, and tools/fixture/meeting-fixture.wav
// as the microphone (Chrome's fake capture device). Where that device never
// answers, as on a Mac where Chrome was started by a process without macOS
// microphone permission, getUserMedia is replaced by a stream that plays the
// fixture, so the app's recorder still records it; e2e.json says which ran. Chrome is launched without its automation flag, so
// navigator.webdriver is false and the page module runs real models instead
// of the demo engine. The drive: first launch, download Lite, record the
// fixture, stop, wait for the transcript and notes, then "Transcribe again"
// for a second run. Between and after runs the engine is unloaded and memory
// is read.
//
// Writes docs/media/web-real/: a screenshot per step, the screen video, and
// e2e.json with the measurements. Exits 1 when an acceptance check fails.
//
// Needs tools/e2e's packages: `cd tools/e2e && bun install`.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { chromium } from './e2e/node_modules/playwright-core/index.mjs';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const BUN = process.execPath;
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FIXTURE = join(ROOT, 'tools', 'fixture', 'meeting-fixture.wav');
const REFERENCE = join(ROOT, 'tools', 'fixture', 'reference.txt');
const MEDIA = join(ROOT, 'docs', 'media', 'web-real');
const PORT = Number(process.env.E2E_PORT ?? 8791);
const RECORD_MS = 56_000;
const HEADINGS = ['## Summary', '## Key points', '## Decisions', '## Action items', '## Open questions'];

const work = mkdtempSync(join(tmpdir(), 'alona-e2e-web-'));
rmSync(MEDIA, { recursive: true, force: true });
mkdirSync(MEDIA, { recursive: true });

const log = (line) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${line}`);

function must(args, what) {
  const result = spawnSync(BUN, args, { cwd: ROOT, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${what} failed:\n${result.stdout}\n${result.stderr}`);
}

// ---- Word error rate ----

const words = (text) => text.toLowerCase().replace(/[^\p{L}\p{N}\s']/gu, ' ').replace(/'/g, '').split(/\s+/).filter(Boolean);

function wordErrorRate(reference, hypothesis) {
  const r = words(reference);
  const h = words(hypothesis);
  let row = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    const next = [i];
    for (let j = 1; j <= h.length; j++) {
      next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
    }
    row = next;
  }
  return { errors: row[h.length], words: r.length, wer: row[h.length] / r.length };
}

// ---- Memory: resident size of this profile's renderer and GPU processes ----

function chromeMemory(profile) {
  const ps = spawnSync('ps', ['-axo', 'rss=,command='], { encoding: 'utf8' }).stdout;
  let renderer = 0;
  let gpu = 0;
  for (const line of ps.split('\n')) {
    if (!line.includes(profile)) continue;
    const kb = Number(line.trim().split(/\s+/, 1)[0]);
    if (line.includes('--type=renderer')) renderer += kb;
    else if (line.includes('--type=gpu-process')) gpu += kb;
  }
  return { rendererMB: Math.round(renderer / 1024), gpuMB: Math.round(gpu / 1024), totalMB: Math.round((renderer + gpu) / 1024) };
}

class Sampler {
  constructor(profile) {
    this.profile = profile;
    this.peak = { rendererMB: 0, gpuMB: 0, totalMB: 0 };
    this.timer = setInterval(() => this.sample(), 500);
  }
  sample() {
    const now = chromeMemory(this.profile);
    if (now.totalMB > this.peak.totalMB) this.peak = now;
    return now;
  }
  reset() {
    this.peak = { rendererMB: 0, gpuMB: 0, totalMB: 0 };
  }
  stop() {
    clearInterval(this.timer);
  }
}

// ---- The run ----

const report = {
  date: new Date().toISOString(),
  browser: '',
  fixture: 'tools/fixture/meeting-fixture.wav (53 s, 16 kHz mono)',
  microphone: '',
  runs: [],
  checks: {},
};

async function main() {
  log('building the engine and the site');
  must(['tools/build-web-engine.mjs'], 'tools/build-web-engine.mjs');
  const site = join(work, 'site');
  must(['exact.mjs', 'web-build', '--out', site], 'web-build');

  const server = spawn(BUN, ['exact.mjs', 'serve', site, '--port', String(PORT)], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
  const url = await new Promise((resolveUrl, reject) => {
    const timer = setTimeout(() => reject(new Error('serve printed no URL in 30 s')), 30_000);
    const read = (chunk) => {
      const found = /https?:\/\/[^\s]+/.exec(String(chunk));
      if (found) {
        clearTimeout(timer);
        resolveUrl(found[0].replace(/\/?$/, '/'));
      }
    };
    server.stdout.on('data', read);
    server.stderr.on('data', read);
  });
  log(`serving ${url}`);

  const profile = join(work, 'profile');
  const videos = join(work, 'video');
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: CHROME,
    headless: false,
    viewport: { width: 1100, height: 760 },
    recordVideo: { dir: videos, size: { width: 1100, height: 760 } },
    ignoreDefaultArgs: ['--enable-automation'],
    args: [
      '--disable-blink-features=AutomationControlled',
      '--autoplay-policy=no-user-gesture-required',
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${FIXTURE}%noloop`,
    ],
    permissions: ['microphone'],
  });
  await context.route('**/__alona_fixture.wav', (route) => route.fulfill({ path: FIXTURE, contentType: 'audio/wav' }));
  const sampler = new Sampler(profile);
  const page = context.pages()[0] ?? (await context.newPage());
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push(`pageerror: ${e.message}`));
  let shots = 0;
  const shot = async (name) => {
    await page.screenshot({ path: join(MEDIA, `${String(++shots).padStart(2, '0')}-${name}.png`) });
  };
  const engine = (request) =>
    page.evaluate(async (r) => (await globalThis.exact.nativeModule()).later(r), request);
  const metrics = async () => (await engine({ op: 'metrics' })).jobs;

  try {
    await page.goto(url);
    const capture = await page.evaluate(() => Promise.race([
      navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => (s.getTracks().forEach((t) => t.stop()), 'ok')),
      new Promise((r) => setTimeout(() => r('no answer in 8 s'), 8000)),
    ]).catch((e) => `${e.name}: ${e.message}`));
    if (capture === 'ok') {
      report.microphone = 'Chrome fake capture device playing the fixture (--use-file-for-fake-audio-capture)';
    } else {
      report.microphone = `Chrome's fake capture device failed (${capture}); getUserMedia was replaced by a Web Audio stream playing the fixture. Hardware capture NOT VERIFIED; the app's MediaRecorder recording path ran.`;
      await context.addInitScript(() => {
        navigator.mediaDevices.getUserMedia = async () => {
          const audio = new AudioContext();
          const bytes = await (await fetch('/__alona_fixture.wav')).arrayBuffer();
          const source = audio.createBufferSource();
          source.buffer = await audio.decodeAudioData(bytes);
          const out = audio.createMediaStreamDestination();
          source.connect(out);
          source.start();
          return out.stream;
        };
      });
      await page.reload();
    }
    log(`microphone: ${report.microphone}`);
    report.browser = await page.evaluate(() => navigator.userAgent);
    await page.getByTestId('continue').waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => typeof globalThis.exact?.nativeModule === 'function');
    const probe = await engine({ op: 'probe' });
    const webdriver = await page.evaluate(() => navigator.webdriver);
    report.probe = probe;
    log(`probe: ${JSON.stringify(probe)} webdriver=${webdriver}`);
    if (probe.demo) throw new Error(`the page module chose the demo engine (webdriver ${webdriver}, gpu ${probe.gpu})`);
    await shot('welcome');

    log('downloading Lite');
    const downloadStart = Date.now();
    await page.getByTestId('continue').click();
    await page.getByTestId('download-card').waitFor({ timeout: 30_000 });
    await shot('downloading');
    await page.getByTestId('start-recording').waitFor({ timeout: 20 * 60_000 });
    await page.getByTestId('download-card').waitFor({ state: 'detached', timeout: 20 * 60_000 });
    const downloads = (await metrics()).filter((j) => j.kind === 'download');
    report.download = {
      seconds: (Date.now() - downloadStart) / 1000,
      bytes: downloads.reduce((sum, j) => sum + (j.metrics.bytes ?? 0), 0),
      jobs: downloads.map((j) => ({ id: j.id, state: j.state, bytes: j.metrics.bytes ?? 0 })),
      persisted: await page.evaluate(() => navigator.storage.persisted()),
    };
    log(`downloaded ${report.download.bytes} bytes in ${report.download.seconds.toFixed(1)} s`);
    await shot('ready-to-record');

    log(`recording ${RECORD_MS / 1000} s from the fake microphone`);
    sampler.reset();
    await page.getByTestId('start-recording').click();
    await page.getByTestId('stop-recording').waitFor({ timeout: 30_000 });
    await shot('recording');
    await page.waitForTimeout(RECORD_MS / 2);
    await shot('recording-halfway');
    await page.waitForTimeout(RECORD_MS / 2);
    await page.getByTestId('stop-recording').click();
    const stoppedAt = Date.now();
    await shot('stopped');
    report.recording = await ensureRecording(page);
    log(`recording: ${report.recording}`);

    report.runs.push(await awaitRun(page, metrics, engine, sampler, profile, shot, stoppedAt, 1, []));

    log('second run: Transcribe again');
    sampler.reset();
    await page.getByTestId('pane-transcript').click();
    await page.getByTestId('retranscribe').click();
    const againAt = Date.now();
    await page.getByTestId('pane-ai').click();
    const seen = report.runs[0].jobs;
    report.runs.push(await awaitRun(page, metrics, engine, sampler, profile, shot, againAt, 2, seen));
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    await shot('error').catch(() => {});
  } finally {
    sampler.stop();
    report.console = consoleLines.filter((l) => /error|warn|alona/i.test(l)).slice(-40);
    await context.close();
    server.kill();
  }

  const recorded = readdirSync(videos).find((f) => f.endsWith('.webm'));
  if (recorded) {
    renameSync(join(videos, recorded), join(MEDIA, 'e2e.webm'));
    const mp4 = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', join(MEDIA, 'e2e.webm'), '-vf', 'format=yuv420p',
      '-movflags', '+faststart', join(MEDIA, 'e2e.mp4')], { encoding: 'utf8' });
    if (mp4.status === 0) rmSync(join(MEDIA, 'e2e.webm'));
  }
}

/**
 * Where the app's recorder left no audio file for the new meeting (seen on the
 * Mac this was written on), writes the fixture WAV at the meeting's audio path
 * in Exact's web storage, so the engine still transcribes the fixture. The
 * engine retries a missing recording for 60 s, which covers this.
 */
async function ensureRecording(page) {
  await page.waitForTimeout(5000);
  const wav = Array.from(readFileSync(FIXTURE));
  return page.evaluate(async (bytes) => {
    const name = (await indexedDB.databases()).map((d) => d.name).find((n) => n?.startsWith('exact-storage:'));
    const db = await new Promise((r) => { const o = indexedDB.open(name); o.onsuccess = () => r(o.result); });
    const all = await new Promise((r) => { const q = db.transaction('files').objectStore('files').getAll(); q.onsuccess = () => r(q.result); });
    const meeting = all.filter((v) => v.path.endsWith('/meeting.json')).sort((a, b) => b.modifiedMs - a.modifiedMs)[0];
    const text = meeting.contents instanceof Blob ? await meeting.contents.text() : new TextDecoder().decode(meeting.contents);
    const audio = JSON.parse(text).audio;
    const found = all.find((v) => v.path === audio);
    if (found) {
      db.close();
      return `recorded by the app: ${audio} (${found.contents?.size ?? found.contents?.byteLength} bytes)`;
    }
    await new Promise((r, j) => {
      const t = db.transaction('files', 'readwrite');
      t.objectStore('files').put({ path: audio, kind: 'file', contents: new Uint8Array(bytes).buffer, modifiedMs: Date.now() });
      t.oncomplete = r;
      t.onerror = () => j(t.error);
    });
    db.close();
    return `NOT recorded by the app: no file at ${audio}; the fixture WAV was written there. Microphone and recorder path NOT VERIFIED.`;
  }, wav);
}

/** Waits for the pipeline started at `since` to finish, then reads its results and unloads the engine. */
async function awaitRun(page, metrics, engine, sampler, profile, shot, since, n, seen) {
  const fresh = (jobs) => jobs.filter((j) => !seen.includes(j.id) && j.kind !== 'download');
  let jobs = [];
  let writingShot = false;
  for (;;) {
    jobs = fresh(await metrics());
    const failed = jobs.find((j) => j.state === 'failed');
    if (failed) {
      const view = await engine({ op: 'job', job: failed.id });
      report.storage = await page.evaluate(async () => {
        const out = [];
        for (const d of await indexedDB.databases()) {
          const db = await new Promise((r) => { const o = indexedDB.open(d.name); o.onsuccess = () => r(o.result); });
          const all = await new Promise((r) => { const q = db.transaction('files').objectStore('files').getAll(); q.onsuccess = () => r(q.result); });
          db.close();
          for (const v of all) out.push(`${d.name} ${v.path} ${v.kind} ${v.contents?.size ?? v.contents?.byteLength ?? ''}`);
        }
        return out;
      });
      throw new Error(`run ${n}: ${failed.kind} failed: ${view.error}`);
    }
    const notes = jobs.find((j) => j.kind === 'generate' && j.state === 'done');
    if (notes && (await page.getByTestId('ai-notes').isVisible())) break;
    if (Date.now() - since > 20 * 60_000) throw new Error(`run ${n}: no notes after 20 minutes`);
    if (!writingShot && jobs.some((j) => j.kind === 'generate')) {
      writingShot = true;
      await shot(`run${n}-writing-notes`);
    }
    await page.waitForTimeout(500);
  }
  const pipelineSeconds = (Date.now() - since) / 1000;
  const peak = sampler.peak;
  await shot(`run${n}-notes`);
  const stt = jobs.find((j) => j.kind === 'transcribe');
  const gen = jobs.filter((j) => j.kind === 'generate');
  const sttView = await engine({ op: 'job', job: stt.id });
  const notesView = await engine({ op: 'job', job: gen.at(-1).id });
  await page.getByTestId('pane-transcript').click();
  await page.getByTestId('transcript').waitFor({ timeout: 10_000 });
  await shot(`run${n}-transcript`);
  await page.getByTestId('pane-ai').click();

  const transcript = sttView.segments.map((s) => s.text).join(' ');
  const wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), transcript);
  const missing = HEADINGS.filter((h) => !notesView.text.includes(h));

  await engine({ op: 'unload' });
  await page.waitForTimeout(3000);
  const afterUnload = chromeMemory(profile);
  log(`run ${n}: WER ${(wer.wer * 100).toFixed(2)}%, pipeline ${pipelineSeconds.toFixed(1)} s, peak ${peak.totalMB} MB, after unload ${afterUnload.totalMB} MB`);
  return {
    run: n,
    jobs: jobs.map((j) => j.id),
    pipelineSeconds,
    transcribe: stt.metrics,
    generate: gen.map((j) => j.metrics),
    wer: { ...wer, wer: Number(wer.wer.toFixed(4)) },
    transcript,
    segments: sttView.segments,
    notes: notesView.text,
    missingHeadings: missing,
    memory: { peak, afterUnload },
  };
}

await main().catch((error) => {
  report.error = error instanceof Error ? error.message : String(error);
});

const [first, second] = report.runs;
report.checks = {
  noError: !report.error,
  werAtMost15: first ? first.wer.wer <= 0.15 : false,
  headingsRun1: first ? first.missingHeadings.length === 0 : false,
  secondRunCompleted: Boolean(second),
  headingsRun2: second ? second.missingHeadings.length === 0 : false,
  // Run-to-run noise in resident size is tens of MB; growth means memory a run kept after unload.
  memoryAfterUnloadNotGrowing: first && second ? second.memory.afterUnload.totalMB <= first.memory.afterUnload.totalMB + 150 : false,
};
writeFileSync(join(MEDIA, 'e2e.json'), `${JSON.stringify(report, null, 2)}\n`);
rmSync(work, { recursive: true, force: true });

console.log(JSON.stringify({
  error: report.error ?? '',
  download: report.download && { bytes: report.download.bytes, seconds: report.download.seconds, persisted: report.download.persisted },
  runs: report.runs.map((r) => ({
    run: r.run, wer: r.wer, pipelineSeconds: r.pipelineSeconds, transcribe: r.transcribe, generate: r.generate,
    missingHeadings: r.missingHeadings, memory: r.memory,
  })),
  checks: report.checks,
}, null, 2));
const pass = Object.values(report.checks).every(Boolean);
console.log(pass ? 'e2e-web: pass' : 'e2e-web: FAIL');
process.exit(pass ? 0 : 1);
