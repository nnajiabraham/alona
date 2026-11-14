#!/usr/bin/env bun
// Drives Alona's desktop shell (desktop/) through the UI with Playwright's Electron support:
//
//   bun tools/e2e-desktop.mjs                          unpacked shell, this machine's Electron, real models
//   bun tools/e2e-desktop.mjs --exe /opt/Alona/alona --platform linux --allow-demo --no-video
//
// Without --exe it runs desktop/ on the Electron in desktop/node_modules and
// serves dist/desktop-site (bun tools/build-desktop.mjs site writes it). With
// --exe it launches an installed app. The microphone is Chromium's fake capture
// device playing tools/fixture/meeting-fixture.wav, and the shell's own
// permission handler decides whether the page gets it. Playwright's automation
// flag is switched off, so navigator.webdriver is false and the page module
// picks the real engine wherever it finds a real WebGPU adapter.
//
// Where it finds none (a container has no GPU) the page module answers with the
// demo engine and says so on screen. --allow-demo accepts that: the flows run,
// and the real-model checks are reported as not applicable. Without it, the
// demo engine fails the run.
//
// Writes docs/media/desktop/<platform>/: a screenshot per step, e2e.mp4 (or
// .webm), and e2e.json, which also lists every network origin Chromium's net
// log saw. Exits 1 when a check fails.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { _electron } from './e2e/node_modules/playwright-core/index.mjs';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const FIXTURE = join(ROOT, 'tools', 'fixture', 'meeting-fixture.wav');
const REFERENCE = join(ROOT, 'tools', 'fixture', 'reference.txt');
const HEADINGS = ['Summary', 'Key points', 'Decisions', 'Action items', 'Open questions'];
const HOST = { darwin: 'macos', linux: 'linux', win32: 'windows' }[process.platform] ?? process.platform;

const { values: opts } = parseArgs({
  options: {
    exe: { type: 'string' },
    platform: { type: 'string', default: HOST },
    'allow-demo': { type: 'boolean', default: false },
    'record-seconds': { type: 'string' },
    // Playwright's screencast stalled the page under software rendering in the Linux container.
    'no-video': { type: 'boolean', default: false },
  },
});

const MEDIA = join(ROOT, 'docs', 'media', 'desktop', opts.platform);
const work = mkdtempSync(join(tmpdir(), 'alona-e2e-desktop-'));
const NETLOG = join(work, 'netlog.json');
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
    for (let j = 1; j <= h.length; j++) {
      next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
    }
    row = next;
  }
  return { errors: row[h.length], words: r.length, wer: Number((row[h.length] / r.length).toFixed(4)) };
}

/** Resident size of the app's process tree, in MB. */
function treeMemoryMB(rootPid) {
  const rows = spawnSync('ps', ['-axo', 'pid=,ppid=,rss='], { encoding: 'utf8' }).stdout.trim().split('\n')
    .map((line) => line.trim().split(/\s+/).map(Number));
  const inTree = new Set([rootPid]);
  for (let grew = true; grew;) {
    grew = false;
    for (const [pid, ppid] of rows) {
      if (inTree.has(ppid) && !inTree.has(pid)) {
        inTree.add(pid);
        grew = true;
      }
    }
  }
  return Math.round(rows.filter(([pid]) => inTree.has(pid)).reduce((sum, [, , kb]) => sum + kb, 0) / 1024);
}

/** Every scheme://host the net log saw a request for. */
function networkOrigins() {
  if (!existsSync(NETLOG)) return ['net log missing'];
  const origins = new Set();
  for (const found of readFileSync(NETLOG, 'utf8').matchAll(/"url":"([a-z-]+:\/\/[^/"]*)/g)) origins.add(found[1]);
  return [...origins].sort();
}

const report = {
  date: new Date().toISOString(),
  platform: opts.platform,
  app: opts.exe ?? 'desktop/ on desktop/node_modules/electron',
  fixture: 'tools/fixture/meeting-fixture.wav (53 s, 16 kHz mono)',
  checks: {},
};

async function main() {
  const executablePath = opts.exe ?? join(ROOT, 'desktop', 'node_modules', 'electron', 'dist',
    ...(process.platform === 'darwin' ? ['Electron.app', 'Contents', 'MacOS', 'Electron'] : [process.platform === 'win32' ? 'electron.exe' : 'electron']));
  const args = [
    '--disable-blink-features=AutomationControlled',
    '--use-fake-device-for-media-stream',
    // A sandboxed audio service cannot open the fixture and captures silence (measured on macOS: peak 0).
    '--disable-features=AudioServiceOutOfProcess',
    `--use-file-for-fake-audio-capture=${FIXTURE}%noloop`,
    `--user-data-dir=${join(work, 'profile')}`,
    `--log-net-log=${NETLOG}`,
    ...(opts.exe ? [] : [join(ROOT, 'desktop')]),
  ];
  const app = await _electron.launch({
    executablePath,
    args,
    ...(opts['no-video'] ? {} : { recordVideo: { dir: join(work, 'video'), size: { width: 1040, height: 760 } } }),
    timeout: 60_000,
  });
  const mainLog = [];
  const keep = (chunk) => mainLog.push(...String(chunk).split('\n').filter((l) => l.startsWith('[alona]')));
  app.process().stdout.on('data', keep);
  app.process().stderr.on('data', keep);
  const pid = app.process().pid;
  let peakMB = 0;
  const sampler = setInterval(() => { peakMB = Math.max(peakMB, treeMemoryMB(pid)); }, 500);

  const page = await app.firstWindow();
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push(`pageerror: ${e.message}`));
  let shots = 0;
  const shot = async (name) => page.screenshot({ path: join(MEDIA, `${String(++shots).padStart(2, '0')}-${name}.png`) });
  const engine = (request) => page.evaluate(async (r) => (await globalThis.exact.nativeModule()).later(r), request);

  try {
    report.window = await app.evaluate(({ BrowserWindow }) => {
      const w = BrowserWindow.getAllWindows()[0];
      return { count: BrowserWindow.getAllWindows().length, title: w.getTitle(), size: w.getSize(), minimumSize: w.getMinimumSize() };
    });
    await page.getByTestId('continue').waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => typeof globalThis.exact?.nativeModule === 'function');
    report.page = await page.evaluate(async () => {
      const adapter = await navigator.gpu?.requestAdapter({ powerPreference: 'high-performance' }).catch(() => null);
      return {
        url: location.href,
        crossOriginIsolated,
        sharedArrayBuffer: typeof SharedArrayBuffer === 'function',
        webdriver: navigator.webdriver,
        userAgent: navigator.userAgent,
        webgpuAdapter: adapter ? { vendor: adapter.info.vendor, architecture: adapter.info.architecture, description: adapter.info.description, shaderF16: adapter.features.has('shader-f16') } : null,
      };
    });
    report.probe = await engine({ op: 'probe' });
    report.engine = report.probe.demo ? 'demo' : 'real';
    log(`page ${JSON.stringify(report.page)}`);
    log(`probe ${JSON.stringify(report.probe)}`);
    await shot('first-launch-device-check');
    if (report.probe.demo && !opts['allow-demo']) throw new Error(`the page module chose the demo engine: ${report.probe.demoReason}`);

    log('downloading models');
    const downloadStart = Date.now();
    await page.getByTestId('continue').click();
    await page.getByTestId('download-card').waitFor({ timeout: 30_000 });
    await shot('downloading');
    await page.getByTestId('start-recording').waitFor({ timeout: 20 * 60_000 });
    await page.getByTestId('download-card').waitFor({ state: 'detached', timeout: 20 * 60_000 });
    report.download = { seconds: (Date.now() - downloadStart) / 1000 };
    if (report.engine === 'real') {
      const jobs = (await engine({ op: 'metrics' })).jobs.filter((j) => j.kind === 'download');
      report.download.bytes = jobs.reduce((sum, j) => sum + (j.metrics.bytes ?? 0), 0);
    }
    log(`download ${JSON.stringify(report.download)}`);
    await shot('ready-to-record');

    const recordMs = Number(opts['record-seconds'] ?? (report.engine === 'real' ? 56 : 8)) * 1000;
    log(`recording ${recordMs / 1000} s from the fake microphone`);
    await page.getByTestId('start-recording').click();
    await page.getByTestId('stop-recording').waitFor({ timeout: 30_000 });
    await shot('recording');
    await page.waitForTimeout(recordMs);
    await shot('recording-end');
    await page.getByTestId('stop-recording').click();
    const stoppedAt = Date.now();
    report.recording = await recordedFile(page);
    log(`recording ${JSON.stringify(report.recording)}`);

    await page.getByTestId('ai-notes').waitFor({ timeout: 20 * 60_000 });
    while (report.engine === 'real') {
      const jobs = (await engine({ op: 'metrics' })).jobs;
      const failed = jobs.find((j) => j.state === 'failed');
      if (failed) throw new Error(`${failed.kind} failed: ${(await engine({ op: 'job', job: failed.id })).error}`);
      if (jobs.some((j) => j.kind === 'generate' && j.state === 'done')) break;
      if (Date.now() - stoppedAt > 20 * 60_000) throw new Error('no notes 20 minutes after stop');
      await page.waitForTimeout(500);
    }
    await page.waitForTimeout(1000);
    report.stopToNotesSeconds = (Date.now() - stoppedAt) / 1000;
    await shot('notes');
    const shownNotes = await page.getByTestId('ai-notes').innerText();
    report.notesOnScreen = shownNotes;
    report.missingHeadingsOnScreen = HEADINGS.filter((h) => !shownNotes.includes(h));

    if (report.engine === 'real') {
      const jobs = (await engine({ op: 'metrics' })).jobs.filter((j) => j.kind !== 'download');
      const stt = jobs.find((j) => j.kind === 'transcribe');
      const gen = jobs.filter((j) => j.kind === 'generate' && j.state === 'done').at(-1);
      const sttView = await engine({ op: 'job', job: stt.id });
      const notesView = await engine({ op: 'job', job: gen.id });
      report.transcript = sttView.segments.map((s) => s.text).join(' ');
      report.wer = wordErrorRate(readFileSync(REFERENCE, 'utf8'), report.transcript);
      report.transcribe = stt.metrics;
      report.generate = gen.metrics;
      report.notes = notesView.text;
      report.missingHeadings = HEADINGS.map((h) => `## ${h}`).filter((h) => !notesView.text.includes(h));
      log(`WER ${(report.wer.wer * 100).toFixed(2)}%, stop to notes ${report.stopToNotesSeconds.toFixed(1)} s`);
    }

    await page.getByTestId('pane-transcript').click();
    await page.getByTestId('transcript').waitFor({ timeout: 10_000 });
    await shot('transcript');
    await page.getByTestId('pane-ai').click();

    await page.goBack();
    await page.getByTestId('open-settings').click();
    await page.getByTestId('settings').waitFor({ timeout: 10_000 });
    await shot('settings');
    report.settingsDevice = await page.getByTestId('settings-device').innerText();

    report.blockedLinks = await app.evaluate(async ({ BrowserWindow }) => {
      const contents = BrowserWindow.getAllWindows()[0].webContents;
      await contents.executeJavaScript("window.open('https://example.com/'); location.href = 'https://example.com/';");
      await new Promise((r) => setTimeout(r, 1500));
      return { windows: BrowserWindow.getAllWindows().length, url: contents.getURL() };
    });
    report.peakMemoryMB = peakMB;
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    await shot('error').catch(() => {});
  } finally {
    clearInterval(sampler);
    report.console = consoleLines.filter((l) => /error|warn|alona/i.test(l)).slice(-40);
    await app.close().catch(() => {});
    report.mainProcess = mainLog;
    report.networkOrigins = networkOrigins();
  }
  const video = join(work, 'video');
  const recorded = existsSync(video) ? readdirSync(video).find((f) => f.endsWith('.webm')) : undefined;
  if (recorded) {
    renameSync(join(video, recorded), join(MEDIA, 'e2e.webm'));
    const mp4 = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', join(MEDIA, 'e2e.webm'), '-vf', 'format=yuv420p',
      '-movflags', '+faststart', join(MEDIA, 'e2e.mp4')], { encoding: 'utf8' });
    if (mp4.status === 0) rmSync(join(MEDIA, 'e2e.webm'));
  }
}

/** The new meeting's audio file in Exact's web storage, as the app's recorder left it. */
async function recordedFile(page) {
  await page.waitForTimeout(3000);
  return page.evaluate(async () => {
    const name = (await indexedDB.databases()).map((d) => d.name).find((n) => n?.startsWith('exact-storage:'));
    if (!name) return { found: false, why: 'no exact-storage database' };
    const db = await new Promise((r) => { const o = indexedDB.open(name); o.onsuccess = () => r(o.result); });
    const all = await new Promise((r) => { const q = db.transaction('files').objectStore('files').getAll(); q.onsuccess = () => r(q.result); });
    db.close();
    const meeting = all.filter((v) => v.path.endsWith('/meeting.json')).sort((a, b) => b.modifiedMs - a.modifiedMs)[0];
    if (!meeting) return { found: false, why: 'no meeting.json' };
    const text = meeting.contents instanceof Blob ? await meeting.contents.text() : new TextDecoder().decode(meeting.contents);
    const audio = JSON.parse(text).audio;
    const file = all.find((v) => v.path === audio);
    return { found: Boolean(file), path: audio, bytes: file ? (file.contents?.size ?? file.contents?.byteLength) : 0 };
  });
}

await main().catch((error) => {
  report.error = error instanceof Error ? error.message : String(error);
});

const real = report.engine === 'real';
const allowedOrigin = (o) => o === 'alona://app' || /^https:\/\/([a-z0-9-]+\.)*(huggingface\.co|hf\.co)$/.test(o) || /^(blob|data):/.test(o);
report.checks = {
  noError: !report.error,
  oneWindowTitledAlona: report.window?.count === 1 && report.window?.title === 'Alona',
  crossOriginIsolated: report.page?.crossOriginIsolated === true,
  firstLaunchShowsDeviceCheck: shotExists('first-launch-device-check'),
  appRecordedTheMicrophone: report.recording?.found === true && report.recording.bytes > 0,
  notesOnScreenHaveFiveHeadings: report.missingHeadingsOnScreen?.length === 0,
  werAtMost15: real ? report.wer?.wer <= 0.15 : 'not applicable: demo engine',
  notesHaveFiveHeadings: real ? report.missingHeadings?.length === 0 : 'not applicable: demo engine',
  otherOriginsRefused: report.blockedLinks?.windows === 1 && report.blockedLinks?.url.startsWith('alona://app/'),
  networkOnlyAppAndModelHosts: report.networkOrigins?.every(allowedOrigin),
};
function shotExists(name) {
  return readdirSync(MEDIA).some((f) => f.endsWith(`-${name}.png`));
}
writeFileSync(join(MEDIA, 'e2e.json'), `${JSON.stringify(report, null, 2)}\n`);
rmSync(work, { recursive: true, force: true });

console.log(JSON.stringify({
  error: report.error ?? '', engine: report.engine, page: report.page, download: report.download, recording: report.recording,
  wer: report.wer, stopToNotesSeconds: report.stopToNotesSeconds, transcribe: report.transcribe, generate: report.generate,
  peakMemoryMB: report.peakMemoryMB, networkOrigins: report.networkOrigins, mainProcess: report.mainProcess, checks: report.checks,
}, null, 2));
const pass = Object.values(report.checks).every((v) => v !== false);
console.log(pass ? 'e2e-desktop: pass' : 'e2e-desktop: FAIL');
process.exit(pass ? 0 : 1);
