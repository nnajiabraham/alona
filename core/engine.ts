import type { Host, Segment } from './types';

/** One downloadable file of a model, verified by size and SHA-256 after download. */
export interface ModelFile {
  url: string;
  name: string;
  bytes: number;
  sha256: string;
}

/** A model as one host's runtime loads it. `runtime` names the loader the host's engine uses. */
export interface Artifact {
  id: string;
  runtime: string;
  files: ModelFile[];
}

export interface DeviceFacts {
  host: Host;
  memoryGB: number;
  cores: number;
  gpu: boolean;
  gpuMaxBufferGB: number;
  storageFreeGB: number;
  formFactor: 'phone' | 'desktop';
  appleSilicon: boolean;
  iosBrowser: boolean;
  description: string;
}

export type JobState = 'running' | 'done' | 'failed' | 'unknown';

/**
 * A long-running engine job as seen by one poll. `unknown` means the engine
 * has no record of the id, which happens after the app restarts.
 */
export interface JobView {
  id: string;
  state: JobState;
  progress: number;
  text: string;
  segments: Segment[];
  error: string;
}

export type EngineRequest =
  | { op: 'probe' }
  | { op: 'installed'; artifacts: Artifact[] }
  | { op: 'download'; job: string; artifact: Artifact }
  | { op: 'remove'; artifact: Artifact }
  | { op: 'transcribe'; job: string; audio: string; artifact: Artifact }
  | { op: 'generate'; job: string; artifact: Artifact; system: string; prompt: string; maxTokens: number }
  | { op: 'job'; job: string }
  | { op: 'cancel'; job: string }
  | { op: 'unload' };

/**
 * The inference engine of one host. Starting a job is idempotent by job id:
 * starting an id that already exists returns its current view.
 */
export interface Engine {
  probe(): Promise<DeviceFacts>;
  installed(artifacts: Artifact[]): Promise<string[]>;
  download(job: string, artifact: Artifact): Promise<JobView>;
  /** Deletes the artifact's files and forgets its download job, so a later download starts fresh. */
  remove(artifact: Artifact): Promise<void>;
  transcribe(job: string, audio: string, artifact: Artifact): Promise<JobView>;
  generate(job: string, artifact: Artifact, system: string, prompt: string, maxTokens: number): Promise<JobView>;
  job(job: string): Promise<JobView>;
  cancel(job: string): Promise<void>;
  unload(): Promise<void>;
}

export class EngineReplyError extends Error {}

function record(raw: unknown, what: string): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new EngineReplyError(`The engine's ${what} reply is not an object.`);
  }
  return raw as Record<string, unknown>;
}

const num = (value: unknown, fallback = 0): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : fallback;
const str = (value: unknown): string => (typeof value === 'string' ? value : '');

function parseSegments(raw: unknown): Segment[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((item) => {
    const s = record(item, 'segment');
    return { start: num(s.start), end: num(s.end), text: str(s.text) };
  });
}

const JOB_STATES: readonly JobState[] = ['running', 'done', 'failed', 'unknown'];

export function parseJobView(raw: unknown): JobView {
  const r = record(raw, 'job');
  const state = JOB_STATES.find((s) => s === r.state);
  if (!state) throw new EngineReplyError(`The engine's job reply has no known state: ${str(r.state)}`);
  return {
    id: str(r.id),
    state,
    progress: Math.min(1, Math.max(0, num(r.progress))),
    text: str(r.text),
    segments: parseSegments(r.segments),
    error: str(r.error),
  };
}

const HOSTS: readonly Host[] = ['web', 'macos', 'ios', 'android'];

export function parseDeviceFacts(raw: unknown): DeviceFacts {
  const r = record(raw, 'probe');
  const host = HOSTS.find((h) => h === r.host);
  if (!host) throw new EngineReplyError(`The engine's probe reply names no known host: ${str(r.host)}`);
  return {
    host,
    memoryGB: num(r.memoryGB),
    cores: num(r.cores, 1),
    gpu: r.gpu === true,
    gpuMaxBufferGB: num(r.gpuMaxBufferGB),
    storageFreeGB: num(r.storageFreeGB),
    formFactor: r.formFactor === 'phone' ? 'phone' : 'desktop',
    appleSilicon: r.appleSilicon === true,
    iosBrowser: r.iosBrowser === true,
    description: str(r.description),
  };
}

function parseInstalled(raw: unknown): string[] {
  const ids = record(raw, 'installed').ids;
  return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : [];
}

/** The engine reached through a host's native module, which answers one JSON reply per request. */
export function engineOver(later: (request: EngineRequest) => Promise<unknown>): Engine {
  return {
    probe: async () => parseDeviceFacts(await later({ op: 'probe' })),
    installed: async (artifacts) => parseInstalled(await later({ op: 'installed', artifacts })),
    download: async (job, artifact) => parseJobView(await later({ op: 'download', job, artifact })),
    remove: async (artifact) => void (await later({ op: 'remove', artifact })),
    transcribe: async (job, audio, artifact) => parseJobView(await later({ op: 'transcribe', job, audio, artifact })),
    generate: async (job, artifact, system, prompt, maxTokens) =>
      parseJobView(await later({ op: 'generate', job, artifact, system, prompt, maxTokens })),
    job: async (job) => parseJobView(await later({ op: 'job', job })),
    cancel: async (job) => void (await later({ op: 'cancel', job })),
    unload: async () => void (await later({ op: 'unload' })),
  };
}
