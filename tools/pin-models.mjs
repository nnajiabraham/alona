#!/usr/bin/env bun
// Writes core/artifacts.json: every model file the app downloads, pinned to a
// repository revision, with its size and SHA-256. Rerun it to move a pin:
//
//   bun tools/pin-models.mjs
//
// Sizes and hashes of large files come from the Hugging Face API. Small files
// that are not stored in LFS, and files hosted on GitHub, are downloaded once
// and hashed here.
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const HF = 'https://huggingface.co';

const VAD = { url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx', name: 'silero_vad.onnx' };

const hf = (repo, paths) => ({ repo, paths });

// One entry per artifact id. `runtime` names the loader a host's engine uses.
const SPECS = {
  'moonshine-base-en.sherpa': {
    runtime: 'sherpa-moonshine',
    from: hf('csukuangfj2/sherpa-onnx-moonshine-base-en-quantized-2026-02-27', {
      'encoder_model.ort': 'encoder_model.ort',
      'decoder_model_merged.ort': 'decoder_model_merged.ort',
      'tokens.txt': 'tokens.txt',
    }),
    extra: [VAD],
  },
  'parakeet-tdt-0.6b-v3.sherpa': {
    runtime: 'sherpa-transducer',
    from: hf('csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8', {
      'encoder.int8.onnx': 'encoder.int8.onnx',
      'decoder.int8.onnx': 'decoder.int8.onnx',
      'joiner.int8.onnx': 'joiner.int8.onnx',
      'tokens.txt': 'tokens.txt',
    }),
    extra: [VAD],
  },
  'qwen3.5-0.8b.gguf': {
    runtime: 'llama',
    from: hf('unsloth/Qwen3.5-0.8B-GGUF', { 'Qwen3.5-0.8B-Q4_K_M.gguf': 'model.gguf' }),
  },
  'qwen3.5-2b.gguf': {
    runtime: 'llama',
    from: hf('unsloth/Qwen3.5-2B-GGUF', { 'Qwen3.5-2B-Q4_K_M.gguf': 'model.gguf' }),
  },
  'qwen3.5-9b.gguf': {
    runtime: 'llama',
    from: hf('unsloth/Qwen3.5-9B-GGUF', { 'Qwen3.5-9B-Q4_K_M.gguf': 'model.gguf' }),
  },
};

async function json(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.json();
}

async function hashOf(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  return { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}

async function pinned({ repo, paths }) {
  const revision = (await json(`${HF}/api/models/${repo}`)).sha;
  const tree = await json(`${HF}/api/models/${repo}/tree/${revision}`);
  return Promise.all(
    Object.entries(paths).map(async ([path, name]) => {
      const entry = tree.find((e) => e.path === path);
      if (!entry) throw new Error(`${repo} has no ${path} at ${revision}`);
      const url = `${HF}/${repo}/resolve/${revision}/${path}`;
      if (entry.lfs) return { url, name, bytes: entry.lfs.size, sha256: entry.lfs.oid };
      return { url, name, ...(await hashOf(url)) };
    }),
  );
}

const artifacts = {};
for (const [id, spec] of Object.entries(SPECS)) {
  const files = await pinned(spec.from);
  for (const extra of spec.extra ?? []) files.push({ ...extra, ...(await hashOf(extra.url)) });
  artifacts[id] = { id, runtime: spec.runtime, files };
  const total = files.reduce((sum, f) => sum + f.bytes, 0);
  console.log(`${id}: ${files.length} files, ${(total / 1e6).toFixed(1)} MB`);
}
writeFileSync(join(ROOT, 'core', 'artifacts.json'), `${JSON.stringify(artifacts, null, 2)}\n`);
