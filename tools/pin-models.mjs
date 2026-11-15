#!/usr/bin/env bun
// Writes core/artifacts.json: every model file the app downloads, pinned to a
// repository revision, with its size and SHA-256. Rerun it to move a pin:
//
//   bun tools/pin-models.mjs            every artifact
//   bun tools/pin-models.mjs <id>…      only these; the rest keep their pins
//
// Sizes and hashes of large files come from the Hugging Face API. Small files
// that are not stored in LFS, and files hosted on GitHub, are downloaded once
// and hashed here.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const HF = 'https://huggingface.co';

const VAD = { url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx', name: 'silero_vad.onnx' };

const hf = (repo, paths) => ({ repo, paths });
// transformers.js reads a repository's files by their paths in it, so a web artifact keeps them.
const sameNames = (...paths) => Object.fromEntries(paths.map((p) => [p, p]));

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
  // The web engine (modules/web) loads these with transformers.js on WebGPU:
  // exactly the files it requests for the dtypes engine/web/src/worker.js names.
  'moonshine-base.onnx': {
    runtime: 'transformers-moonshine',
    from: hf('onnx-community/moonshine-base-ONNX', sameNames(
      'config.json', 'generation_config.json', 'preprocessor_config.json', 'tokenizer.json', 'tokenizer_config.json',
      'onnx/encoder_model.onnx', 'onnx/decoder_model_merged_q4.onnx',
    )),
  },
  'qwen3.5-0.8b.onnx': {
    runtime: 'transformers-qwen',
    from: hf('onnx-community/Qwen3.5-0.8B-ONNX', sameNames(
      'config.json', 'generation_config.json', 'tokenizer.json', 'tokenizer_config.json',
      'onnx/embed_tokens_q4f16.onnx', 'onnx/embed_tokens_q4f16.onnx_data',
      'onnx/decoder_model_merged_q4f16.onnx', 'onnx/decoder_model_merged_q4f16.onnx_data',
    )),
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
  const tree = await json(`${HF}/api/models/${repo}/tree/${revision}?recursive=true`);
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

const OUT = join(ROOT, 'core', 'artifacts.json');
const only = process.argv.slice(2);
const unknown = only.filter((id) => !SPECS[id]);
if (unknown.length > 0) throw new Error(`no such artifact: ${unknown.join(', ')}`);
const previous = only.length > 0 ? JSON.parse(readFileSync(OUT, 'utf8')) : {};

const artifacts = {};
for (const [id, spec] of Object.entries(SPECS)) {
  if (only.length > 0 && !only.includes(id)) {
    if (!previous[id]) throw new Error(`${id} has no pin yet; pin it too`);
    artifacts[id] = previous[id];
    continue;
  }
  const files = await pinned(spec.from);
  for (const extra of spec.extra ?? []) files.push({ ...extra, ...(await hashOf(extra.url)) });
  artifacts[id] = { id, runtime: spec.runtime, files };
  const total = files.reduce((sum, f) => sum + f.bytes, 0);
  console.log(`${id}: ${files.length} files, ${(total / 1e6).toFixed(1)} MB`);
}
writeFileSync(OUT, `${JSON.stringify(artifacts, null, 2)}\n`);
