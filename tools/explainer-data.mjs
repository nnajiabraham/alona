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

const flows = {};
for (const target of dirs(MEDIA)) {
  for (const flow of dirs(join(MEDIA, target))) {
    const dir = join(MEDIA, target, flow);
    const shots = files(dir, '.png');
    const videos = files(dir, '.mp4').concat(files(dir, '.webm'));
    if (shots.length === 0 && videos.length === 0) continue;
    (flows[target] ??= {})[flow] = {
      shots: shots.map((name) => ({ src: `../media/${target}/${flow}/${name}`, label: name.replace(/^\d+-/, '').replace(/\.png$/, '').replaceAll('-', ' ') })),
      video: videos[0] ? `../media/${target}/${flow}/${videos[0]}` : '',
    };
  }
}

const checks = [];
for (const target of dirs(MEDIA)) {
  for (const name of files(join(MEDIA, target), '.json')) {
    try {
      const result = JSON.parse(readFileSync(join(MEDIA, target, name), 'utf8'));
      checks.push({ target, file: `docs/media/${target}/${name}`, ...result });
    } catch {
      console.warn(`skipped unreadable ${target}/${name}`);
    }
  }
}

writeFileSync(join(ROOT, 'docs', 'explainer', 'data.js'), `window.ALONA = ${JSON.stringify({ flows, checks }, null, 1)};\n`);
console.log(`explainer data: ${Object.keys(flows).length} targets, ${checks.length} real-model checks`);
