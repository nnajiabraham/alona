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
for (const target of dirs(MEDIA)) {
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

const checks = [];
for (const target of dirs(MEDIA)) {
  for (const name of files(join(MEDIA, target), '.json')) {
    try {
      const raw = JSON.parse(readFileSync(join(MEDIA, target, name), 'utf8'));
      const result = raw.browser ? fromWeb(raw) : raw;
      checks.push({ target, file: `docs/media/${target}/${name}`, ...result });
    } catch (e) {
      console.warn(`skipped ${target}/${name}: ${e.message}`);
    }
  }
}

writeFileSync(join(ROOT, 'docs', 'explainer', 'data.js'), `window.ALONA = ${JSON.stringify({ flows, checks }, null, 1)};\n`);
console.log(`explainer data: ${Object.keys(flows).length} targets, ${checks.length} real-model checks`);
