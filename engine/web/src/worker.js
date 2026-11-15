// Alona's web inference worker. It holds at most one model and runs one job at
// a time; the page module (modules/web/index.js) queues jobs and terminates
// this worker to switch models, because only termination returns the memory.
//
// In:  {type: 'transcribe', id, model, pcm}   pcm: 16 kHz mono Float32Array
//      {type: 'generate', id, model, prompt, maxTokens}
//      {type: 'cancel', id}
// Out: {id, type: 'segment', segment, progress}
//      {id, type: 'text', text, progress}
//      {id, type: 'done', text, metrics}
//      {id, type: 'error', error}
// `model` is {runtime, repo, revision}.
import {
  AutoModelForCausalLM,
  AutoTokenizer,
  env,
  InterruptableStoppingCriteria,
  LogitsProcessor,
  pipeline,
  random,
  TextStreamer,
} from '@huggingface/transformers';

env.backends.onnx.wasm.wasmPaths = new URL('./ort/', import.meta.url).href;
env.backends.onnx.wasm.proxy = false;
env.allowLocalModels = false;
env.useBrowserCache = true;
// Model files come only from the Cache API, where the page module put them
// after checking them. A file that is not there fails the load; the library
// never reaches the network on its own. A 404 lets optional files read as absent.
env.fetch = async (url) => {
  console.warn(`alona engine: not downloaded: ${url}`);
  return new Response(null, { status: 404, statusText: 'Not downloaded' });
};

const RATE = 16000;

const RUNTIMES = {
  'transformers-moonshine': { kind: 'speech', dtype: { encoder_model: 'fp32', decoder_model_merged: 'q4' } },
  'transformers-qwen': { kind: 'writer', dtype: { embed_tokens: 'q4f16', decoder_model_merged: 'q4f16' } },
};

class Cancelled extends Error {
  constructor() {
    super('Cancelled.');
  }
}

/** @type {{key: string, speech?: any, tokenizer?: any, model?: any} | null} */
let loaded = null;
const cancelled = new Set();
/** @type {InterruptableStoppingCriteria | null} */
let stopping = null;
let running = '';

async function load(model) {
  const key = `${model.repo}@${model.revision}`;
  if (loaded?.key === key) return loaded;
  const runtime = RUNTIMES[model.runtime];
  if (!runtime) throw new Error(`This browser build cannot run the ${model.runtime} runtime.`);
  if (loaded) throw new Error('The engine already holds another model.');
  // Not every loader passes `revision` on to the files it reads (the config, for one), so the pin goes in the path every file is read from.
  env.remotePathTemplate = `{model}/resolve/${encodeURIComponent(model.revision)}/`;
  const options = { device: 'webgpu', dtype: runtime.dtype };
  if (runtime.kind === 'speech') {
    loaded = { key, speech: await pipeline('automatic-speech-recognition', model.repo, options) };
  } else {
    const tokenizer = await AutoTokenizer.from_pretrained(model.repo);
    loaded = { key, tokenizer, model: await AutoModelForCausalLM.from_pretrained(model.repo, options) };
  }
  return loaded;
}

function check(id) {
  if (cancelled.has(id)) throw new Cancelled();
}

// Moonshine drifts on long inputs, so the recording is cut into windows of at
// most MAX_WINDOW seconds, each ending at the quietest moment of its last
// stretch. A window with almost no speech is skipped, because Moonshine
// invents words for silence.
const FRAME = 480;
const MIN_WINDOW = 12;
const MAX_WINDOW = 20;
const PAD = 0.2;

function frameLevels(pcm) {
  const levels = new Float32Array(Math.ceil(pcm.length / FRAME));
  for (let f = 0; f < levels.length; f++) {
    let sum = 0;
    const end = Math.min(pcm.length, (f + 1) * FRAME);
    for (let i = f * FRAME; i < end; i++) sum += pcm[i] * pcm[i];
    levels[f] = Math.sqrt(sum / Math.max(1, end - f * FRAME));
  }
  return levels;
}

export function windows(pcm) {
  const levels = frameLevels(pcm);
  const sorted = Float32Array.from(levels).sort();
  const floor = sorted[Math.floor(sorted.length * 0.1)] ?? 0;
  const speaking = Math.max(0.005, floor * 3);
  const perSecond = RATE / FRAME;
  const out = [];
  let start = 0;
  while (start < levels.length) {
    let end = levels.length;
    if (end - start > MAX_WINDOW * perSecond) {
      const from = start + Math.round(MIN_WINDOW * perSecond);
      const to = start + Math.round(MAX_WINDOW * perSecond);
      end = from;
      for (let f = from; f < to; f++) if (levels[f] < levels[end]) end = f;
    }
    let first = -1;
    let last = -1;
    let voiced = 0;
    for (let f = start; f < end; f++) {
      if (levels[f] <= speaking) continue;
      if (first < 0) first = f;
      last = f;
      voiced++;
    }
    if (voiced / perSecond >= 0.3) {
      const from = Math.max(start, first - Math.round(PAD * perSecond));
      const to = Math.min(end, last + 1 + Math.round(PAD * perSecond));
      out.push({ start: (from * FRAME) / RATE, end: Math.min(pcm.length, to * FRAME) / RATE });
    }
    start = end;
  }
  return out;
}

async function transcribe({ id, model, pcm }) {
  const began = performance.now();
  const { speech } = await load(model);
  const loadedAt = performance.now();
  const parts = windows(pcm);
  const total = pcm.length / RATE;
  const segments = [];
  for (const part of parts) {
    check(id);
    const out = await speech(pcm.subarray(Math.round(part.start * RATE), Math.round(part.end * RATE)));
    const text = (Array.isArray(out) ? out[0].text : out.text).trim();
    const segment = { start: part.start, end: part.end, text };
    if (text !== '') segments.push(segment);
    self.postMessage({ id, type: 'segment', segment: text === '' ? null : segment, progress: part.end / total });
  }
  check(id);
  const done = performance.now();
  return {
    text: '',
    metrics: { loadMs: Math.round(loadedAt - began), transcribeMs: Math.round(done - loadedAt), audioSeconds: total, windows: parts.length },
  };
}

/**
 * llama.cpp's presence penalty, as the Swift Writer uses it: every token that
 * appears among the last `window` generated tokens loses `penalty` from its logit.
 */
class PresencePenalty extends LogitsProcessor {
  constructor(promptLength, penalty, window) {
    super();
    this.promptLength = promptLength;
    this.penalty = penalty;
    this.window = window;
  }

  _call(inputIds, logits) {
    for (let i = 0; i < inputIds.length; i++) {
      const data = logits[i].data;
      const recent = inputIds[i].slice(Math.max(this.promptLength, inputIds[i].length - this.window));
      for (const token of new Set(recent)) data[Number(token)] -= this.penalty;
    }
    return logits;
  }
}

async function generate({ id, model, prompt, maxTokens }) {
  const began = performance.now();
  const { tokenizer, model: llm } = await load(model);
  const loadedAt = performance.now();
  check(id);
  const inputs = tokenizer(prompt, { add_special_tokens: false, return_tensor: true });
  const promptTokens = inputs.input_ids.dims.at(-1);
  const endOfTurn = tokenizer.convert_tokens_to_ids(['<|im_end|>', '<|endoftext|>']).filter((t) => typeof t === 'number');
  let text = '';
  let tokens = 0;
  let firstAt = 0;
  let posted = 0;
  const streamer = new TextStreamer(tokenizer, {
    skip_prompt: true,
    skip_special_tokens: true,
    token_callback_function: () => {
      tokens++;
      if (firstAt === 0) firstAt = performance.now();
    },
    callback_function: (piece) => {
      text += piece;
      const now = performance.now();
      if (now - posted > 200) {
        posted = now;
        self.postMessage({ id, type: 'text', text, progress: Math.min(1, tokens / maxTokens) });
      }
    },
  });
  stopping = new InterruptableStoppingCriteria();
  if (cancelled.has(id)) stopping.interrupt();
  // Qwen's recommended sampling for non-thinking replies, as in the Swift Writer. The fixed seed keeps a rerun's notes the same.
  random.seed(42);
  try {
    await llm.generate({
      ...inputs,
      max_new_tokens: maxTokens,
      do_sample: true,
      temperature: 0.7,
      top_k: 20,
      top_p: 0.8,
      eos_token_id: endOfTurn,
      logits_processor: [new PresencePenalty(promptTokens, 1.5, 64)],
      stopping_criteria: [stopping],
      streamer,
    });
  } finally {
    stopping = null;
  }
  check(id);
  const end = performance.now();
  return {
    text: text.trim(),
    metrics: {
      loadMs: Math.round(loadedAt - began),
      promptTokens,
      tokens,
      ttftMs: firstAt ? Math.round(firstAt - loadedAt) : 0,
      generateMs: Math.round(end - loadedAt),
      tokensPerSecond: tokens > 1 && firstAt ? Number(((tokens - 1) / ((end - firstAt) / 1000)).toFixed(2)) : 0,
    },
  };
}

const OPS = { transcribe, generate };

self.onmessage = async ({ data }) => {
  if (data.type === 'cancel') {
    cancelled.add(data.id);
    if (running === data.id) stopping?.interrupt();
    return;
  }
  const op = OPS[data.type];
  running = data.id;
  try {
    if (!op) throw new Error(`unknown worker message ${data.type}`);
    self.postMessage({ id: data.id, type: 'done', ...(await op(data)) });
  } catch (error) {
    self.postMessage({ id: data.id, type: 'error', error: error instanceof Error ? error.message : String(error) });
  } finally {
    running = '';
    cancelled.delete(data.id);
  }
};
