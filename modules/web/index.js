// Alona's inference engine in the browser. It answers the JSON protocol in
// core/engine.ts through `native.later`: every request gets one reply at once,
// and long work runs as a job the app polls by id.
//
// Models run in ./worker.js (transformers.js and ONNX Runtime on WebGPU, built
// by tools/build-web-engine.mjs). The worker holds one model at a time and
// runs one job at a time; switching models terminates it, because only
// termination gives its memory back. Downloads run here on the page.
//
// Exact imports this file in Bun at build time, so nothing at the top level
// touches a browser API.
import { sha256 } from './sha256.js';

/** The Cache API store transformers.js reads model files from, keyed by file URL. */
const CACHE = 'transformers-cache';
const HF_FILE = /^https:\/\/huggingface\.co\/(.+)\/resolve\/([^/]+)\/(.+)$/;
const RATE = 16000;

/**
 * @typedef {{url: string, name: string, bytes: number, sha256: string}} ModelFile
 * @typedef {{id: string, runtime: string, files: ModelFile[]}} Artifact
 * @typedef {{start: number, end: number, text: string}} Segment
 * @typedef {{
 *   id: string, kind: 'download' | 'transcribe' | 'generate', artifact: string,
 *   state: 'running' | 'done' | 'failed', progress: number, text: string, segments: Segment[], error: string,
 *   cancelled: boolean, abort: AbortController, metrics: Record<string, number>, startedAt: number, endedAt: number,
 * }} Job
 */

/** @type {Map<string, Job>} */
const jobs = new Map();
/** Model jobs run one at a time, in the order they were started. */
let queue = Promise.resolve();
/** @type {Worker | null} */
let worker = null;
/** The artifact id the worker has loaded or is loading. */
let holds = '';
/** @type {Map<string, {resolve: (m: {text: string, metrics: Record<string, number>}) => void, reject: (e: Error) => void}>} */
const waiting = new Map();
let persistAsked = false;
/** The Exact databases the last missing-recording read looked in, for its error. */
let seen = '';

const message = (error) => (error instanceof Error ? error.message : String(error));

function view(job) {
  return { id: job.id, state: job.state, progress: job.progress, text: job.text, segments: job.segments, error: job.error };
}

const unknown = (id) => ({ id, state: 'unknown', progress: 0, text: '', segments: [], error: '' });

/** @returns {Artifact} */
function artifactOf(raw) {
  if (typeof raw !== 'object' || raw === null || typeof raw.id !== 'string' || raw.id === '' || !Array.isArray(raw.files)) {
    throw new Error('The request names no model artifact.');
  }
  const files = raw.files.map((f) => {
    const pinned = typeof f?.url === 'string' && typeof f?.name === 'string' && Number(f?.bytes) > 0 && typeof f?.sha256 === 'string' && f.sha256 !== '';
    if (!pinned) throw new Error(`The artifact ${raw.id} has a file without a pinned size and checksum.`);
    return { url: f.url, name: f.name, bytes: Number(f.bytes), sha256: f.sha256 };
  });
  return { id: raw.id, runtime: typeof raw.runtime === 'string' ? raw.runtime : '', files };
}

/** The Hugging Face repository and revision every file of a web artifact comes from. */
function modelOf(artifact) {
  const found = artifact.files.map((f) => HF_FILE.exec(f.url));
  const first = found[0];
  if (!first || found.some((m) => !m || m[1] !== first[1] || m[2] !== first[2])) {
    throw new Error(`The artifact ${artifact.id} is not one Hugging Face repository at one revision.`);
  }
  return { runtime: artifact.runtime, repo: first[1], revision: decodeURIComponent(first[2]) };
}

// ---- Device ----

/**
 * The browser's GPU when it is a real one transformers.js can run the models
 * on: WebGPU with shader-f16, and not a fallback or software adapter such as
 * SwiftShader, which headless Chrome reports.
 */
async function realGpu() {
  try {
    const adapter = await globalThis.navigator.gpu?.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) return null;
    const info = adapter.info ?? {};
    const software = info.isFallbackAdapter === true || adapter.isFallbackAdapter === true
      || /swiftshader|llvmpipe|software/i.test(`${info.vendor ?? ''} ${info.architecture ?? ''} ${info.description ?? ''}`);
    if (software || !adapter.features.has('shader-f16')) return null;
    return { maxBufferGB: adapter.limits.maxBufferSize / 2 ** 30 };
  } catch {
    return null;
  }
}

function platform() {
  const nav = globalThis.navigator;
  const ua = nav.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && nav.maxTouchPoints > 1);
  const os = ios ? 'iOS' : /Android/.test(ua) ? 'Android' : /Mac OS X|Macintosh/.test(ua) ? 'macOS'
    : /Windows/.test(ua) ? 'Windows' : /CrOS/.test(ua) ? 'ChromeOS' : /Linux/.test(ua) ? 'Linux' : '';
  const browser = /Edg\//.test(ua) ? 'Edge' : /OPR\//.test(ua) ? 'Opera' : /Firefox\/|FxiOS/.test(ua) ? 'Firefox'
    : /Chrome\/|CriOS/.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'A browser';
  const phone = ios || nav.userAgentData?.mobile === true || /Android|Mobi/.test(ua);
  return { ios, phone, description: os ? `${browser} on ${os}` : browser };
}

async function probe() {
  const nav = globalThis.navigator;
  const gpu = await realGpu();
  const estimate = await nav.storage?.estimate?.().catch(() => null);
  const { ios, phone, description } = platform();
  const facts = {
    host: 'web',
    memoryGB: Number(nav.deviceMemory) || 0,
    cores: nav.hardwareConcurrency || 1,
    gpu: gpu !== null,
    gpuMaxBufferGB: gpu?.maxBufferGB ?? 0,
    storageFreeGB: estimate ? Math.max(0, (estimate.quota ?? 0) - (estimate.usage ?? 0)) / 1e9 : 0,
    formFactor: phone ? 'phone' : 'desktop',
    appleSilicon: false,
    iosBrowser: ios,
    description,
  };
  // The demo engine answers instead of this one under browser automation
  // (navigator.webdriver) and where there is no real WebGPU adapter: Exact's
  // test runs use headless Chrome on a software GPU and must never download
  // models. tools/e2e-web.mjs drives a real Chrome that is not flagged as
  // automated, so it gets this engine.
  const demoReason = nav.webdriver === true
    ? 'This browser is under automation, so no models are loaded.'
    : gpu === null ? 'This browser has no WebGPU, so Alona cannot run its models here.' : '';
  return { ...facts, demo: demoReason !== '', demoReason };
}

// ---- Model files ----

async function cachedSize(cache, file) {
  const hit = await cache.match(file.url);
  if (!hit) return -1;
  const header = Number(hit.headers.get('content-length'));
  return Number.isFinite(header) && header > 0 ? header : (await hit.blob()).size;
}

async function installed(cache, artifact) {
  for (const file of artifact.files) {
    if ((await cachedSize(cache, file)) !== file.bytes) return false;
  }
  return true;
}

/**
 * Fetches one file into the cache. Every file is checked against its pinned
 * size and SHA-256 while it streams (the hash is computed here, in JavaScript,
 * because Web Crypto cannot hash a stream), and only a file that passes both
 * is put in the cache, so a cached file is a whole, verified file.
 */
async function fetchFile(cache, file, signal, onBytes) {
  const response = await fetch(file.url, { signal });
  if (!response.ok || !response.body) throw new Error(`Downloading ${file.name} failed: HTTP ${response.status}.`);
  const hash = sha256();
  const reader = response.body.getReader();
  /** @type {Blob[]} */
  const parts = [];
  /** @type {Uint8Array[]} */
  let pending = [];
  let pendingBytes = 0;
  let got = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    hash.update(value);
    pending.push(value);
    pendingBytes += value.length;
    got += value.length;
    if (got > file.bytes) throw new Error(`${file.name} is larger than its pinned size.`);
    // Spilling into Blobs lets the browser keep a large file out of the JS heap.
    if (pendingBytes >= 32 << 20) {
      parts.push(new Blob(pending));
      pending = [];
      pendingBytes = 0;
    }
    onBytes(got);
  }
  parts.push(new Blob(pending));
  if (got !== file.bytes) throw new Error(`${file.name} arrived with ${got} bytes, not ${file.bytes}.`);
  if (hash.hex() !== file.sha256) throw new Error(`${file.name} failed its checksum.`);
  const body = new Blob(parts);
  await cache.put(file.url, new Response(body, { headers: { 'content-type': 'application/octet-stream', 'content-length': String(got) } }));
}

async function download(job, artifact) {
  const cache = await caches.open(CACHE);
  const total = artifact.files.reduce((sum, f) => sum + f.bytes, 0) || 1;
  let before = 0;
  let fetched = 0;
  for (const file of artifact.files) {
    if (job.cancelled) throw new Error('Cancelled.');
    if ((await cachedSize(cache, file)) !== file.bytes) {
      await fetchFile(cache, file, job.abort.signal, (got) => {
        job.progress = Math.min(1, (before + got) / total);
      });
      fetched += file.bytes;
    }
    before += file.bytes;
    job.progress = Math.min(1, before / total);
  }
  job.metrics = { bytes: fetched };
  if (!persistAsked) {
    persistAsked = true;
    await globalThis.navigator.storage?.persist?.().catch(() => false);
  }
}

async function remove(artifact) {
  for (const [id, job] of jobs) {
    if (job.artifact !== artifact.id) continue;
    job.cancelled = true;
    job.abort.abort();
    if (job.kind === 'download') jobs.delete(id);
  }
  if (holds === artifact.id) stopWorker();
  const cache = await caches.open(CACHE);
  await Promise.all(artifact.files.map((f) => cache.delete(f.url)));
}

// ---- Recordings ----

/**
 * Reads an app:/ file from Exact's web storage. Exact has no supported way for
 * a page module to read the app's files, so this reads its IndexedDB layout
 * (host/web/storage-fs.js): database `exact-storage:<store>`, object store
 * `files`, records `{path, contents}`. The store name varies (development and
 * agent stores carry a suffix), so every Exact database is tried.
 */
async function readAppFile(path) {
  const names = (await indexedDB.databases()).map((d) => d.name ?? '').filter((n) => n.startsWith('exact-storage:'));
  for (const name of names) {
    const record = await new Promise((resolve, reject) => {
      const open = indexedDB.open(name);
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result;
        if (!db.objectStoreNames.contains('files')) {
          db.close();
          resolve(null);
          return;
        }
        const get = db.transaction('files', 'readonly').objectStore('files').get(path);
        get.onsuccess = () => {
          db.close();
          resolve(get.result ?? null);
        };
        get.onerror = () => {
          db.close();
          reject(get.error);
        };
      };
    });
    if (record?.kind === 'file') {
      return record.contents instanceof Blob ? record.contents.arrayBuffer() : record.contents;
    }
  }
  seen = names.join(', ') || 'no Exact storage';
  return null;
}

/** The recording's bytes. The recorder's last write can land just after the meeting is saved, so a missing file is retried briefly. */
async function readRecording(path) {
  for (let attempt = 0; attempt < 60; attempt++) {
    const bytes = await readAppFile(path);
    if (bytes && bytes.byteLength > 0) return bytes;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`The recording ${path} is missing from this browser's storage (looked in ${seen}).`);
}

/** Any audio the browser can decode, as 16 kHz mono samples. */
async function decode16k(bytes) {
  const audio = await new OfflineAudioContext(1, 1, RATE).decodeAudioData(bytes);
  if (audio.numberOfChannels === 1) return audio.getChannelData(0).slice();
  const mono = new Float32Array(audio.length);
  for (let c = 0; c < audio.numberOfChannels; c++) {
    const channel = audio.getChannelData(c);
    for (let i = 0; i < mono.length; i++) mono[i] += channel[i] / audio.numberOfChannels;
  }
  return mono;
}

// ---- Worker ----

function stopWorker() {
  worker?.terminate();
  worker = null;
  holds = '';
  for (const [, wait] of waiting) wait.reject(new Error('The engine was stopped.'));
  waiting.clear();
}

/** The worker, holding `artifact` or about to load it. A worker that holds another model is replaced. */
function workerFor(artifact) {
  if (worker && holds === artifact.id) return worker;
  stopWorker();
  const next = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
  next.onmessage = ({ data }) => {
    const job = jobs.get(data.id);
    if (data.type === 'segment' && job) {
      if (data.segment) job.segments.push(data.segment);
      job.progress = data.progress;
    } else if (data.type === 'text' && job) {
      job.text = data.text;
      job.progress = data.progress;
    } else if (data.type === 'done' || data.type === 'error') {
      const wait = waiting.get(data.id);
      waiting.delete(data.id);
      if (data.type === 'done') wait?.resolve({ text: data.text, metrics: data.metrics });
      else wait?.reject(new Error(data.error));
    }
  };
  next.onerror = (event) => {
    event.preventDefault();
    const why = new Error(`The engine stopped: ${event.message || 'the browser ended it'}.`);
    for (const [, wait] of waiting) wait.reject(why);
    waiting.clear();
    worker?.terminate();
    worker = null;
    holds = '';
  };
  worker = next;
  holds = artifact.id;
  return next;
}

function inWorker(job, artifact, payload, transfer) {
  const model = modelOf(artifact);
  const target = workerFor(artifact);
  return new Promise((resolve, reject) => {
    waiting.set(job.id, { resolve, reject });
    target.postMessage({ id: job.id, model, ...payload }, transfer);
  });
}

async function requireInstalled(artifact, what) {
  if (!(await installed(await caches.open(CACHE), artifact))) throw new Error(`The ${what} model is not downloaded.`);
}

async function transcribe(job, artifact, audio) {
  await requireInstalled(artifact, 'speech');
  if (!/^app:\/data\/[^\0]+$/.test(audio) || audio.split('/').includes('..')) throw new Error('The recording path is not an app:/data path.');
  const began = performance.now();
  const pcm = await decode16k(await readRecording(audio));
  const decodeMs = performance.now() - began;
  if (job.cancelled) throw new Error('Cancelled.');
  const result = await inWorker(job, artifact, { type: 'transcribe', pcm }, [pcm.buffer]);
  job.metrics = { ...result.metrics, decodeMs: Math.round(decodeMs) };
}

async function generate(job, artifact, prompt, maxTokens) {
  await requireInstalled(artifact, 'notes');
  const result = await inWorker(job, artifact, { type: 'generate', prompt, maxTokens }, []);
  job.text = result.text;
  job.metrics = result.metrics;
}

// ---- Jobs ----

/**
 * Starts `body` as the job `id`, unless that job is running or done: starting is
 * idempotent by id, and a failed job runs again. Model jobs wait their turn in
 * `queue`; downloads do not.
 */
const KEPT_JOBS = 24;

/** Finished jobs hold a transcript or notes. Only the newest few are kept, oldest dropped first. */
function forgetOldJobs() {
  const finished = [...jobs.values()].filter((job) => job.state !== 'running');
  for (const job of finished.slice(0, Math.max(0, finished.length - KEPT_JOBS))) jobs.delete(job.id);
}

function start(id, kind, artifact, body) {
  if (typeof id !== 'string' || id === '') throw new Error('A job needs an id.');
  const existing = jobs.get(id);
  if (existing && existing.state !== 'failed') return view(existing);
  forgetOldJobs();
  /** @type {Job} */
  const job = {
    id, kind, artifact: artifact.id, state: 'running', progress: 0, text: '', segments: [], error: '',
    cancelled: false, abort: new AbortController(), metrics: {}, startedAt: Date.now(), endedAt: 0,
  };
  jobs.set(id, job);
  const run = async () => {
    try {
      if (job.cancelled) throw new Error('Cancelled.');
      await body(job);
      if (job.cancelled) throw new Error('Cancelled.');
      job.progress = 1;
      job.state = 'done';
    } catch (error) {
      job.error = job.cancelled ? 'Cancelled.' : message(error);
      job.state = 'failed';
    } finally {
      job.endedAt = Date.now();
    }
  };
  if (kind === 'download') void run();
  else queue = queue.then(run);
  return view(job);
}

function cancel(id) {
  const job = jobs.get(id);
  if (!job || job.state !== 'running') return;
  job.cancelled = true;
  job.abort.abort();
  if (waiting.has(id)) worker?.postMessage({ type: 'cancel', id });
}

async function handle(request) {
  switch (request?.op) {
    case 'probe':
      return probe();
    case 'installed': {
      const cache = await caches.open(CACHE);
      const ids = [];
      for (const raw of Array.isArray(request.artifacts) ? request.artifacts : []) {
        const artifact = artifactOf(raw);
        if (await installed(cache, artifact)) ids.push(artifact.id);
      }
      return { ids };
    }
    case 'download': {
      const artifact = artifactOf(request.artifact);
      return start(request.job, 'download', artifact, (job) => download(job, artifact));
    }
    case 'remove':
      await remove(artifactOf(request.artifact));
      return {};
    case 'transcribe': {
      const artifact = artifactOf(request.artifact);
      const audio = String(request.audio ?? '');
      return start(request.job, 'transcribe', artifact, (job) => transcribe(job, artifact, audio));
    }
    case 'generate': {
      const artifact = artifactOf(request.artifact);
      const prompt = String(request.prompt ?? '');
      const maxTokens = Number(request.maxTokens) > 0 ? Number(request.maxTokens) : 512;
      return start(request.job, 'generate', artifact, (job) => generate(job, artifact, prompt, maxTokens));
    }
    case 'job': {
      const job = jobs.get(request.job);
      return job ? view(job) : unknown(String(request.job ?? ''));
    }
    case 'cancel':
      cancel(request.job);
      return {};
    case 'unload': {
      // After the job in flight, as on Apple: the queue is the lock on the loaded model.
      const done = queue.then(stopWorker);
      queue = done;
      await done;
      return {};
    }
    // Not part of the protocol: timings and byte counts of this page's jobs, for tools/e2e-web.mjs.
    case 'metrics':
      return {
        jobs: [...jobs.values()].map((j) => ({
          id: j.id, kind: j.kind, artifact: j.artifact, state: j.state, metrics: j.metrics, startedAt: j.startedAt, endedAt: j.endedAt,
        })),
      };
    default:
      throw new Error(`unknown op ${String(request?.op)}`);
  }
}

/** A request the engine cannot answer rejects, so `native.later` fails as Apple's `reply.fail` does. */
export const later = (request) => handle(request);
