import type { Artifact, DeviceFacts, Engine, JobView } from './engine';
import type { Segment } from './types';

export const SIM_SEGMENTS: Segment[] = [
  { start: 0, end: 7, text: 'Thanks for joining everyone. Today we need to decide the launch date for the mobile app and review the open bugs.' },
  { start: 7, end: 15, text: 'The Android build is stable. We fixed the crash on the settings screen yesterday.' },
  { start: 15, end: 21, text: 'The login issue on older phones is still open. I need two more days to finish the fix.' },
  { start: 21, end: 28, text: 'The onboarding screens are final. I will send the updated icons to the team by Thursday.' },
  { start: 28, end: 36, text: 'We launch on the fifteenth of March, as long as the login fix lands by Friday.' },
];

const SIM_NOTES = `Title: Sample notes

> These are sample notes from the demo engine. No model ran, and they do not describe your recording.

## Summary
The team reviewed open bugs and agreed to launch the mobile app on March 15, provided the login fix lands by Friday.

## Key points
- The Android build is stable and the settings crash is fixed.
- The login issue on older phones is still open.
- Onboarding screens are final.

## Decisions
- Launch on March 15 if the login fix lands by Friday.

## Action items
- [ ] Daniel: finish and test the login fix by Friday
- [ ] Karen: send the updated icons by Thursday

## Open questions
- None recorded.`;

export const SIM_DEVICE: DeviceFacts = {
  host: 'web',
  memoryGB: 8,
  cores: 8,
  gpu: true,
  gpuMaxBufferGB: 2,
  storageFreeGB: 64,
  formFactor: 'desktop',
  appleSilicon: false,
  iosBrowser: false,
  description: 'Demo device',
};

export interface SimOptions {
  /** Polls a job stays `running` before it is `done`. */
  polls?: number;
  /** Job ids containing this text fail. */
  failJobsContaining?: string;
  device?: DeviceFacts;
  /** The transcript every transcription returns. `SIM_SEGMENTS` when absent. */
  segments?: Segment[];
  /** The reply to a generate request, from its prompt. `SIM_NOTES` when absent. */
  notes?: (prompt: string) => string;
  /** Where the set of "downloaded" models is kept across launches. In memory when absent. */
  shelf?: { load(): Promise<string[]>; save(ids: string[]): Promise<void> };
}

interface SimJob {
  kind: 'download' | 'transcribe' | 'generate';
  polled: number;
  artifact: string;
  prompt: string;
  cancelled: boolean;
}

/**
 * A stand-in engine with canned results, for tests and for hosts that have no
 * inference module. It keeps jobs in memory, so a fresh instance answers
 * `unknown` for every id, as a real engine does after a restart.
 */
export function simEngine(options: SimOptions = {}): Engine & { forget(): void; unloadCount(): number } {
  const polls = options.polls ?? 2;
  const jobs = new Map<string, SimJob>();
  let unloads = 0;
  let shelf: Set<string> | null = null;
  const installed = async (): Promise<Set<string>> => (shelf ??= new Set(await options.shelf?.load()));
  const keep = async (change: (ids: Set<string>) => void): Promise<void> => {
    const ids = await installed();
    change(ids);
    await options.shelf?.save([...ids]);
  };

  const view = (id: string): JobView => {
    const job = jobs.get(id);
    const base = { id, text: '', segments: [], error: '' };
    if (!job) return { ...base, state: 'unknown', progress: 0 };
    if (job.cancelled) return { ...base, state: 'failed', progress: 0, error: 'Cancelled.' };
    if (options.failJobsContaining && id.includes(options.failJobsContaining)) {
      return { ...base, state: 'failed', progress: 0, error: 'The demo engine was told to fail this job.' };
    }
    if (job.polled < polls) return { ...base, state: 'running', progress: job.polled / polls };
    return {
      ...base,
      state: 'done',
      progress: 1,
      text: job.kind === 'generate' ? (options.notes?.(job.prompt) ?? SIM_NOTES) : '',
      segments: job.kind === 'transcribe' ? (options.segments ?? SIM_SEGMENTS) : [],
    };
  };

  const start = (id: string, kind: SimJob['kind'], artifact: Artifact, prompt = ''): JobView => {
    if (view(id).state === 'failed') jobs.delete(id);
    if (!jobs.has(id)) jobs.set(id, { kind, polled: 0, artifact: artifact.id, prompt, cancelled: false });
    return view(id);
  };

  return {
    probe: async () => options.device ?? SIM_DEVICE,
    installed: async (artifacts) => {
      const ids = await installed();
      return artifacts.map((a) => a.id).filter((id) => ids.has(id));
    },
    download: async (job, artifact) => start(job, 'download', artifact),
    remove: async (artifact) => {
      for (const [id, job] of jobs) if (job.kind === 'download' && job.artifact === artifact.id) jobs.delete(id);
      await keep((ids) => ids.delete(artifact.id));
    },
    transcribe: async (job, _audio, artifact) => start(job, 'transcribe', artifact),
    generate: async (job, artifact, prompt) => start(job, 'generate', artifact, prompt),
    job: async (id) => {
      const job = jobs.get(id);
      if (job) job.polled += 1;
      const now = view(id);
      if (job?.kind === 'download' && now.state === 'done') await keep((ids) => ids.add(job.artifact));
      return now;
    },
    cancel: async (id) => {
      const job = jobs.get(id);
      if (job) job.cancelled = true;
    },
    unload: async () => void (unloads += 1),
    forget: () => jobs.clear(),
    unloadCount: () => unloads,
  };
}
