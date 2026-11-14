#!/usr/bin/env bun
// One tenant's clinic app with real models in a real browser, driven through the UI:
//
//   bun tools/clinic-e2e-web.mjs quillmoor-pilot
//
// The same harness as tools/e2e-web.mjs: installed Google Chrome with a fresh
// profile, WebGPU, no automation flag (so the page runs real models), and
// tools/fixture/clinic-fixture.wav as the microphone, or a Web Audio stream
// playing it where Chrome's fake device never answers. The fixture is a
// synthetic physiotherapy consultation spoken by two macOS `say` voices; its
// words are in tools/fixture/clinic-reference.txt. Synthetic speech is cleaner
// than a real room, so the word error rate here is a floor, not a forecast.
//
// The drive: first launch, download the tenant's default tier, start a note with
// the default template, record the fixture, stop, wait for the transcript and
// draft. Passes when the word error rate is at most 15% and the draft's headings
// are exactly the template's, in order.
//
// Writes docs/media/clinic/<slug>/web-real/: a screenshot per step, the video and
// e2e.json. Needs tools/e2e's packages: `cd tools/e2e && bun install`.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { chromium } from './e2e/node_modules/playwright-core/index.mjs';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const BUN = process.execPath;
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FIXTURE = join(ROOT, 'tools', 'fixture', 'clinic-fixture.wav');
const REFERENCE = join(ROOT, 'tools', 'fixture', 'clinic-reference.txt');
const PORT = Number(process.env.E2E_PORT ?? 8792);
const RECORD_MS = 58_000;

const slug = process.argv[2] ?? 'quillmoor-pilot';
const tenant = (await import(join(ROOT, 'tenants', `${slug}.ts`))).default;
const template = tenant.templates.find((t) => t.id === tenant.defaults.template);
const HEADINGS = template.sections.map((s) => s.heading);
const MEDIA = join(ROOT, 'docs', 'media', 'clinic', slug, 'web-real');

const work = mkdtempSync(join(tmpdir(), 'clinic-e2e-web-'));
rmSync(MEDIA, { recursive: true, force: true });
mkdirSync(MEDIA, { recursive: true });
const log = (line) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${line}`);

const words = (text) => text.toLowerCase().replace(/[^\p{L}\p{N}\s']/gu, ' ').replace(/'/g, '').split(/\s+/).filter(Boolean);

function wordErrorRate(reference, hypothesis) {
  const r = words(reference);
  const h = words(hypothesis);
  let row = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    const next = [i];
    for (let j = 1; j <= h.length; j++) next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
    row = next;
  }
  return { errors: row[h.length], words: r.length, wer: row[h.length] / r.length };
}

const report = { date: new Date().toISOString(), tenant: slug, template: template.id, fixture: 'tools/fixture/clinic-fixture.wav (56 s, 16 kHz mono, macOS say)', checks: {} };

async function main() {
  log(`building ${slug} for the web`);
  const build = spawnSync(BUN, ['tools/tenant.mjs', 'build', slug, 'web'], { cwd: ROOT, encoding: 'utf8' });
  if (build.status !== 0) throw new Error(`build failed:\n${build.stdout}\n${build.stderr}`);
  const site = join(ROOT, '.exact', 'tenants', slug, 'dist');

  const server = spawn(BUN, ['exact.mjs', 'serve', site, '--port', String(PORT)], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
  const url = await new Promise((done, reject) => {
    const timer = setTimeout(() => reject(new Error('serve printed no URL in 30 s')), 30_000);
    const read = (chunk) => {
      const found = /https?:\/\/[^\s]+/.exec(String(chunk));
      if (found) {
        clearTimeout(timer);
        done(found[0].replace(/\/?$/, '/'));
      }
    };
    server.stdout.on('data', read);
    server.stderr.on('data', read);
  });
  log(`serving ${url}`);

  const videos = join(work, 'video');
  const context = await chromium.launchPersistentContext(join(work, 'profile'), {
    executablePath: CHROME,
    headless: false,
    viewport: { width: 1100, height: 760 },
    recordVideo: { dir: videos, size: { width: 1100, height: 760 } },
    ignoreDefaultArgs: ['--enable-automation'],
    args: ['--disable-blink-features=AutomationControlled', '--autoplay-policy=no-user-gesture-required',
      '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${FIXTURE}%noloop`],
    permissions: ['microphone'],
  });
  await context.route('**/__clinic_fixture.wav', (route) => route.fulfill({ path: FIXTURE, contentType: 'audio/wav' }));
  const page = context.pages()[0] ?? (await context.newPage());
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push(`pageerror: ${e.message}`));
  let shots = 0;
  const shot = (name) => page.screenshot({ path: join(MEDIA, `${String(++shots).padStart(2, '0')}-${name}.png`) });
  const engine = (request) => page.evaluate(async (r) => (await globalThis.exact.nativeModule()).later(r), request);
  const jobs = async () => (await engine({ op: 'metrics' })).jobs;

  try {
    await page.goto(url);
    const capture = await page.evaluate(() => Promise.race([
      navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => (s.getTracks().forEach((t) => t.stop()), 'ok')),
      new Promise((r) => setTimeout(() => r('no answer in 8 s'), 8000)),
    ]).catch((e) => `${e.name}: ${e.message}`));
    if (capture === 'ok') {
      report.microphone = 'Chrome fake capture device playing the fixture';
    } else {
      report.microphone = `Chrome's fake capture device failed (${capture}); getUserMedia was replaced by a Web Audio stream playing the fixture. Hardware capture NOT VERIFIED.`;
      await context.addInitScript(() => {
        navigator.mediaDevices.getUserMedia = async () => {
          const audio = new AudioContext();
          const source = audio.createBufferSource();
          source.buffer = await audio.decodeAudioData(await (await fetch('/__clinic_fixture.wav')).arrayBuffer());
          const out = audio.createMediaStreamDestination();
          source.connect(out);
          source.start();
          return out.stream;
        };
      });
      await page.reload();
    }
    log(`microphone: ${report.microphone}`);
    await page.getByTestId('continue').waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => typeof globalThis.exact?.nativeModule === 'function');
    report.probe = await engine({ op: 'probe' });
    if (report.probe.demo) throw new Error(`the page module chose the demo engine (gpu ${report.probe.gpu})`);
    await shot('welcome');

    log(`downloading the ${tenant.defaults.tier} tier`);
    const downloadAt = Date.now();
    await page.getByTestId('continue').click();
    await page.getByTestId('download-card').waitFor({ timeout: 30_000 });
    await shot('downloading');
    await page.getByTestId('download-card').waitFor({ state: 'detached', timeout: 20 * 60_000 });
    report.download = { seconds: (Date.now() - downloadAt) / 1000, bytes: (await jobs()).filter((j) => j.kind === 'download').reduce((s, j) => s + (j.metrics.bytes ?? 0), 0) };
    log(`downloaded ${report.download.bytes} bytes in ${report.download.seconds.toFixed(1)} s`);

    await page.getByTestId('new-note-button').click();
    await page.getByTestId('new-ref').fill('Synthetic fixture');
    await page.getByTestId(`template-${template.id}`).click();
    await shot('new-note');
    await page.getByTestId('start-recording').click();
    await page.getByTestId('stop-recording').waitFor({ timeout: 30_000 });
    await shot('recording');
    log(`recording ${RECORD_MS / 1000} s`);
    await page.waitForTimeout(RECORD_MS);
    await page.getByTestId('stop-recording').click();
    const stoppedAt = Date.now();
    report.recording = await ensureRecording(page);
    log(`recording: ${report.recording}`);

    let done;
    for (;;) {
      const all = (await jobs()).filter((j) => j.kind !== 'download');
      const failed = all.find((j) => j.state === 'failed');
      if (failed) throw new Error(`${failed.kind} failed: ${(await engine({ op: 'job', job: failed.id })).error}`);
      if (all.some((j) => j.kind === 'generate' && j.state === 'done') && (await page.getByTestId('note-text').isVisible())) {
        done = all;
        break;
      }
      if (Date.now() - stoppedAt > 20 * 60_000) throw new Error('no draft after 20 minutes');
      await page.waitForTimeout(500);
    }
    report.pipelineSeconds = (Date.now() - stoppedAt) / 1000;
    await shot('draft');
    const stt = await engine({ op: 'job', job: done.find((j) => j.kind === 'transcribe').id });
    const draft = await engine({ op: 'job', job: done.filter((j) => j.kind === 'generate').at(-1).id });
    await page.getByTestId('pane-transcript').click();
    await page.getByTestId('transcript').waitFor({ timeout: 10_000 });
    await shot('transcript');

    report.transcript = stt.segments.map((s) => s.text).join(' ');
    const wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), report.transcript);
    report.wer = { ...wer, wer: Number(wer.wer.toFixed(4)) };
    report.draft = draft.text;
    report.headings = [...draft.text.matchAll(/^## (.+?)\s*$/gm)].map((m) => m[1]);
    report.transcribe = done.find((j) => j.kind === 'transcribe').metrics;
    report.generate = done.filter((j) => j.kind === 'generate').map((j) => j.metrics);
    log(`WER ${(wer.wer * 100).toFixed(2)}%, headings ${JSON.stringify(report.headings)}, pipeline ${report.pipelineSeconds.toFixed(1)} s`);
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    await shot('error').catch(() => {});
  } finally {
    report.console = consoleLines.filter((l) => /error|warn/i.test(l)).slice(-30);
    await context.close();
    server.kill();
  }
  const recorded = readdirSync(videos).find((f) => f.endsWith('.webm'));
  if (recorded) {
    renameSync(join(videos, recorded), join(MEDIA, 'e2e.webm'));
    const mp4 = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', join(MEDIA, 'e2e.webm'), '-vf', 'format=yuv420p', '-movflags', '+faststart', join(MEDIA, 'e2e.mp4')]);
    if (mp4.status === 0) rmSync(join(MEDIA, 'e2e.webm'));
  }
}

/** As in tools/e2e-web.mjs: where the recorder left no file, writes the fixture at the note's audio path and says so. */
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
    return `NOT recorded by the app: no file at ${audio}; the fixture WAV was written there. Recorder path NOT VERIFIED.`;
  }, wav);
}

await main().catch((error) => {
  report.error = error instanceof Error ? error.message : String(error);
});
report.checks = {
  noError: !report.error,
  werAtMost15: report.wer ? report.wer.wer <= 0.15 : false,
  exactlyTheTemplateHeadings: JSON.stringify(report.headings ?? []) === JSON.stringify(HEADINGS),
};
writeFileSync(join(MEDIA, 'e2e.json'), `${JSON.stringify(report, null, 2)}\n`);
rmSync(work, { recursive: true, force: true });
console.log(JSON.stringify({ error: report.error ?? '', wer: report.wer, headings: report.headings, expected: HEADINGS, pipelineSeconds: report.pipelineSeconds, checks: report.checks }, null, 2));
if (report.draft) console.log(`\n${report.draft}\n`);
const pass = Object.values(report.checks).every(Boolean);
console.log(pass ? 'clinic-e2e-web: pass' : 'clinic-e2e-web: FAIL');
process.exit(pass ? 0 : 1);
