#!/usr/bin/env bun
// Writes docs/explainer/data.js: the list of captured flow media and the
// real-model check results the explainer page shows. Rerun it after
// tools/flows.mjs or an e2e check produces new files:
//
//   bun tools/explainer-data.mjs
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const MEDIA = join(ROOT, 'docs', 'media');

const dirs = (path) => (existsSync(path) ? readdirSync(path).filter((n) => statSync(join(path, n)).isDirectory()).sort() : []);
const files = (path, ext) => readdirSync(path).filter((n) => n.endsWith(ext)).sort();

const media = (target, flow, dir) => {
  const shots = files(dir, '.png');
  const videos = files(dir, '.mp4').concat(files(dir, '.webm'));
  if (shots.length === 0 && videos.length === 0) return null;
  const base = flow === '' ? `../media/${target}` : `../media/${target}/${flow}`;
  return {
    shots: shots.map((name) => ({ src: `${base}/${name}`, label: name.replace(/^\d+-/, '').replace(/\.png$/, '').replaceAll('-', ' ') })),
    video: videos[0] ? `${base}/${videos[0]}` : '',
  };
};

const flows = {};
for (const target of dirs(MEDIA).filter((t) => t !== 'clinic')) {
  // Captures saved straight into a target's folder are one real-model run, not a named flow.
  const loose = media(target, '', join(MEDIA, target));
  if (loose) (flows[target] ??= {})['real-run'] = loose;
  for (const flow of dirs(join(MEDIA, target))) {
    const found = media(target, flow, join(MEDIA, target, flow));
    if (found) (flows[target] ??= {})[flow] = found;
  }
}

const seconds = (ms) => (typeof ms === 'number' ? Number((ms / 1000).toFixed(1)) : null);

/** The web check's result file, in the shape the native check writes. */
function fromWeb(result) {
  const first = result.runs[0];
  const failures = Object.entries(result.checks ?? {}).filter(([, ok]) => ok !== true).map(([name]) => name);
  return {
    host: 'web', tier: 'lite', date: result.date,
    method: {
      audio: `${result.fixture}. ${result.recording}`,
      microphone: result.microphone,
      timing: 'performance.now() in the worker; total is from stopping the recording to notes on screen',
      memory: 'ps resident size of the renderer and GPU processes, sampled every 0.5 s; idle is read 3 s after unload. Resident size also counts freed pages, so it overstates the idle figure',
      browser: result.browser,
    },
    wer: { errors: first.wer.errors, words: first.wer.words, rate: first.wer.wer },
    title: '', transcript: first.transcript, notes: first.notes, failures,
    runs: result.runs.map((r) => ({
      cycle: r.run,
      transcribeSeconds: seconds(r.transcribe.loadMs + r.transcribe.transcribeMs),
      notesSeconds: seconds(r.generate.reduce((sum, g) => sum + g.loadMs + g.generateMs, 0)),
      totalSeconds: Number(r.pipelineSeconds.toFixed(1)),
      peakMB: r.memory.peak.totalMB,
      idleMB: r.memory.afterUnload.totalMB,
      detail: r.generate.map((g) => `${g.promptTokens} prompt tokens, first token after ${seconds(g.ttftMs)} s, ${g.tokensPerSecond} tokens per second`).join('; '),
    })),
    metrics: { 'Download': `${(result.download.bytes / 1e6).toFixed(0)} MB in ${result.download.seconds.toFixed(0)} s`, 'Device': result.probe.description },
  };
}

// A check that did not apply, such as word error rate on the demo engine, is recorded as text, not false.
const failed = (checksOf) => Object.entries(checksOf ?? {}).filter(([, ok]) => ok === false).map(([name]) => name);

/** The desktop shell's and the clinical app's result files: one run each, with word error rate and total time. */
function fromSingleRun(result, host, tier, total, notes, memory) {
  return {
    host, tier, date: result.date,
    method: {
      audio: `${result.fixture}`,
      recording: typeof result.recording === 'string' ? result.recording : `recorded by the app: ${result.recording?.path} (${result.recording?.bytes} bytes)`,
      timing: 'wall time from stopping the recording to the notes on screen',
      engine: result.engine === 'demo' ? 'the demo engine, because this machine gave no real WebGPU adapter' : 'real models',
    },
    wer: result.wer ? { errors: result.wer.errors, words: result.wer.words, rate: result.wer.wer } : undefined,
    title: '', transcript: result.transcript ?? '', notes: notes ?? '', failures: failed(result.checks),
    runs: [{ cycle: 1, transcribeSeconds: null, notesSeconds: null, totalSeconds: Number(total.toFixed(1)), peakMB: memory ?? null, idleMB: null }],
  };
}

const checks = [];
const check = (target, file, read) => {
  try {
    checks.push({ target, file, ...read(JSON.parse(readFileSync(join(ROOT, file), 'utf8'))) });
  } catch (e) {
    console.warn(`skipped ${file}: ${e.message}`);
  }
};
for (const target of dirs(MEDIA).filter((t) => t !== 'clinic' && t !== 'desktop')) {
  for (const name of files(join(MEDIA, target), '.json')) {
    check(target, `docs/media/${target}/${name}`, (raw) => (raw.browser ? fromWeb(raw) : raw));
  }
}
for (const platform of dirs(join(MEDIA, 'desktop'))) {
  check('desktop', `docs/media/desktop/${platform}/e2e.json`, (raw) =>
    fromSingleRun(raw, `desktop shell on ${platform}`, 'lite', raw.stopToNotesSeconds, raw.notes, raw.peakMemoryMB));
}

/** The clinical app's captures: tenant, then target, then flow. */
const clinic = {};
for (const slug of dirs(join(MEDIA, 'clinic'))) {
  for (const target of dirs(join(MEDIA, 'clinic', slug))) {
    const base = join(MEDIA, 'clinic', slug, target);
    for (const name of files(base, '.json')) {
      check('clinic', `docs/media/clinic/${slug}/${target}/${name}`, (raw) =>
        fromSingleRun(raw, `clinical app, ${slug}, web`, 'lite', raw.pipelineSeconds, raw.draft, null));
    }
    for (const flow of dirs(base)) {
      const found = media(`clinic/${slug}/${target}`, flow, join(base, flow));
      if (found) ((clinic[slug] ??= {})[target] ??= {})[flow] = found;
    }
    const loose = media(`clinic/${slug}/${target}`, '', base);
    if (loose) ((clinic[slug] ??= {})[target] ??= {})['real-run'] = loose;
  }
}

writeFileSync(join(ROOT, 'docs', 'explainer', 'data.js'), `window.ALONA = ${JSON.stringify({ flows, checks, clinic }, null, 1)};\n`);
console.log(`explainer data: ${Object.keys(flows).length} targets, ${Object.keys(clinic).length} clinic tenants, ${checks.length} checks`);
