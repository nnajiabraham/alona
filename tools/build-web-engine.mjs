#!/usr/bin/env bun
// Builds the web inference engine into modules/web/, which Exact serves as is:
//
//   bun tools/build-web-engine.mjs
//
// It installs engine/web's pinned packages, bundles engine/web/src/worker.js
// to modules/web/worker.js, and copies ONNX Runtime's wasm from the same
// onnxruntime-web the bundle resolved to modules/web/ort/. Both outputs are
// git-ignored; this script is how they are made.
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const ENGINE = join(ROOT, 'engine', 'web');
const OUT = join(ROOT, 'modules', 'web');
const BUN = process.execPath;

// WebGPU and WASM both run from this one binary in this ORT build; it is the only pair the worker loads.
const ORT_FILES = ['ort-wasm-simd-threaded.asyncify.mjs', 'ort-wasm-simd-threaded.asyncify.wasm'];

function run(args, cwd) {
  const result = spawnSync(BUN, args, { cwd, stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`bun ${args.join(' ')} exited ${result.status}`);
}

const version = (dir) => JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).version;

run(['install', '--frozen-lockfile'], ENGINE);

const pinned = JSON.parse(readFileSync(join(ENGINE, 'package.json'), 'utf8')).dependencies['onnxruntime-web'];
const top = join(ENGINE, 'node_modules', 'onnxruntime-web');
const nested = join(ENGINE, 'node_modules', '@huggingface', 'transformers', 'node_modules', 'onnxruntime-web');
let resolved = top;
try {
  statSync(nested);
  resolved = nested;
} catch {}
const ortVersion = version(resolved);
if (ortVersion !== pinned) {
  throw new Error(`transformers.js resolves onnxruntime-web ${ortVersion}, but engine/web pins ${pinned}. Pin the version it resolves.`);
}

mkdirSync(OUT, { recursive: true });
run(['build', 'src/worker.js', '--target=browser', '--format=esm', '--minify', `--outfile=${join(OUT, 'worker.js')}`], ENGINE);

const bundle = readFileSync(join(OUT, 'worker.js'), 'utf8');
if (!bundle.includes(ortVersion)) {
  throw new Error(`modules/web/worker.js does not carry onnxruntime-web ${ortVersion}; the copied wasm would not match it.`);
}

rmSync(join(OUT, 'ort'), { recursive: true, force: true });
mkdirSync(join(OUT, 'ort'));
for (const file of ORT_FILES) copyFileSync(join(resolved, 'dist', file), join(OUT, 'ort', file));

const size = (path) => `${(statSync(path).size / 1e6).toFixed(1)} MB`;
console.log(`modules/web/worker.js ${size(join(OUT, 'worker.js'))} (onnxruntime-web ${ortVersion})`);
for (const file of ORT_FILES) console.log(`modules/web/ort/${file} ${size(join(OUT, 'ort', file))}`);
