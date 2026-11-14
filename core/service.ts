import { assess, effectiveTier, type Assessment } from './device';
import type { Artifact, DeviceFacts, Engine, JobView } from './engine';
import { demoArtifacts, downloadBytes, LINEUP, shippedTiers, sizeLabel, tierArtifacts, type TierArtifacts } from './models';
import { advance, isWorking, regenerate, retry, type PipelineIO } from './pipeline';
import type { MeetingStore, StoredMeeting } from './store';
import { displayTitle, isTierId, TIERS, type Stage, type TierId } from './types';

export interface TierView {
  id: string;
  label: string;
  blurb: string;
  sttName: string;
  llmName: string;
  downloadLabel: string;
  runnable: boolean;
  reason: string;
  installed: boolean;
  downloading: boolean;
  progress: number;
  error: string;
}

export interface SetupView {
  ready: boolean;
  demo: boolean;
  deviceLine: string;
  recommended: string;
  recommendedLabel: string;
  active: string;
  activeLabel: string;
  activeInstalled: boolean;
  activeDownloading: boolean;
  activeProgress: number;
  activeDownloadLabel: string;
  activeError: string;
  tiers: TierView[];
}

export interface MeetingRow {
  id: string;
  title: string;
  createdAt: number;
  durationS: number;
  status: string;
  statusLabel: string;
  progress: number;
}

export interface SegmentView {
  id: string;
  at: string;
  text: string;
}

export interface MeetingDetail extends MeetingRow {
  found: boolean;
  audio: string;
  error: string;
  aiNotes: string;
  userNotes: string;
  segments: SegmentView[];
}

export interface Reply {
  ok: boolean;
  error: string;
}

const OK: Reply = { ok: true, error: '' };
const refused = (error: string): Reply => ({ ok: false, error });

const downloadJob = (artifact: Artifact): string => `dl.${artifact.id}`;

function statusLabel(stage: Stage): string {
  switch (stage.kind) {
    case 'recorded':
      return 'Waiting to start';
    case 'transcribing':
      return 'Transcribing';
    case 'summarizing':
      return 'Writing notes';
    case 'done':
      return 'Notes ready';
    case 'failed':
      return stage.during === 'transcribing' ? 'Transcription failed' : 'Notes failed';
  }
}

function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const s = total % 60;
  return `${Math.floor(total / 60)}:${s < 10 ? '0' : ''}${s}`;
}

const row = (m: StoredMeeting): MeetingRow => ({
  id: m.id,
  title: displayTitle(m),
  createdAt: m.createdAt,
  durationS: m.durationS,
  status: m.stage.kind,
  statusLabel: statusLabel(m.stage),
  progress: m.progress,
});

const MISSING: MeetingDetail = {
  found: false, id: '', title: '', createdAt: 0, durationS: 0, status: '', statusLabel: '', progress: 0,
  audio: '', error: '', aiNotes: '', userNotes: '', segments: [],
};

function deviceLine(d: DeviceFacts): string {
  const parts = [d.description];
  if (d.memoryGB > 0) parts.push(`${Math.round(d.memoryGB)} GB memory`);
  if (d.gpu) parts.push('GPU');
  return parts.filter((p) => p !== '').join(' · ');
}

interface TierState {
  installed: boolean;
  downloading: boolean;
  progress: number;
  error: string;
}

/**
 * The app's operations over one host's engine and the meeting store. `demo`
 * is true when the host has no inference module and the stand-in engine
 * answers instead.
 */
export function service(engine: Engine, store: MeetingStore, demo: boolean) {
  let facts: DeviceFacts | null = null;
  let ticking = false;

  const device = async (): Promise<DeviceFacts> => (facts ??= await engine.probe());

  const artifactsOf = (d: DeviceFacts, tier: TierId): TierArtifacts | null =>
    demo ? demoArtifacts(tier) : tierArtifacts(d.host, tier);

  const assessment = (d: DeviceFacts): Assessment => assess(d.host, d, demo ? TIERS : shippedTiers(d.host));

  async function tierState(artifacts: TierArtifacts): Promise<TierState> {
    const both = [artifacts.stt, artifacts.llm];
    const have = await engine.installed(both);
    const missing = both.filter((a) => !have.includes(a.id));
    if (missing.length === 0) return { installed: true, downloading: false, progress: 1, error: '' };
    const views: JobView[] = await Promise.all(missing.map((a) => engine.job(downloadJob(a))));
    if (views.every((v) => v.state === 'done') && (await engine.installed(missing)).length === missing.length) {
      return { installed: true, downloading: false, progress: 1, error: '' };
    }
    const total = downloadBytes(artifacts) || 1;
    const weight = (a: Artifact): number => a.files.reduce((sum, f) => sum + f.bytes, 0) || total / both.length;
    const done = both.reduce((sum, a) => {
      const i = missing.indexOf(a);
      return sum + weight(a) * (i < 0 ? 1 : views[i].progress);
    }, 0);
    return {
      installed: false,
      downloading: views.some((v) => v.state === 'running'),
      progress: Math.min(1, done / (both.reduce((sum, a) => sum + weight(a), 0) || 1)),
      error: views.find((v) => v.state === 'failed')?.error ?? '',
    };
  }

  async function activeArtifacts(picked: string): Promise<{ tier: TierId; artifacts: TierArtifacts } | null> {
    const d = await device();
    const tier = effectiveTier(assessment(d), isTierId(picked) ? picked : 'auto');
    const artifacts = artifactsOf(d, tier);
    return artifacts ? { tier, artifacts } : null;
  }

  return {
    async setup(picked: string): Promise<SetupView> {
      const d = await device();
      const a = assessment(d);
      const active = effectiveTier(a, isTierId(picked) ? picked : 'auto');
      const tiers = await Promise.all(
        a.verdicts.map(async (v): Promise<TierView> => {
          const info = LINEUP[v.tier];
          const artifacts = artifactsOf(d, v.tier);
          const state: TierState = artifacts
            ? await tierState(artifacts)
            : { installed: false, downloading: false, progress: 0, error: '' };
          return {
            id: v.tier,
            label: info.label,
            blurb: info.blurb,
            sttName: info.stt.name,
            llmName: info.llm.name,
            downloadLabel: artifacts ? sizeLabel(downloadBytes(artifacts)) : '',
            runnable: v.runnable,
            reason: v.reason,
            ...state,
          };
        }),
      );
      const current = tiers.find((t) => t.id === active);
      return {
        ready: true,
        demo,
        deviceLine: deviceLine(d),
        recommended: a.recommended,
        recommendedLabel: LINEUP[a.recommended].label,
        active,
        activeLabel: LINEUP[active].label,
        activeInstalled: current?.installed ?? false,
        activeDownloading: current?.downloading ?? false,
        activeProgress: current?.progress ?? 0,
        activeDownloadLabel: current?.downloadLabel ?? '',
        activeError: current?.error ?? '',
        tiers,
      };
    },

    async downloadTier(tier: string): Promise<Reply> {
      if (!isTierId(tier)) return refused('Unknown model tier.');
      const artifacts = artifactsOf(await device(), tier);
      if (!artifacts) return refused('This device has no models for that tier.');
      const both = [artifacts.stt, artifacts.llm];
      const have = await engine.installed(both);
      await Promise.all(both.filter((a) => !have.includes(a.id)).map((a) => engine.download(downloadJob(a), a)));
      return OK;
    },

    async removeTier(tier: string): Promise<Reply> {
      if (!isTierId(tier)) return refused('Unknown model tier.');
      const artifacts = artifactsOf(await device(), tier);
      if (!artifacts) return OK;
      await engine.unload();
      await Promise.all([artifacts.stt, artifacts.llm].map((a) => engine.remove(a)));
      return OK;
    },

    /**
     * Advances the oldest unfinished meeting by one step. Meetings run one at
     * a time so only one model is in memory. A tick that arrives while one is
     * still running does nothing.
     */
    async tick(picked: string): Promise<{ working: boolean }> {
      if (ticking) return { working: true };
      ticking = true;
      try {
        const waiting = (await store.list()).filter(isWorking).sort((x, y) => x.createdAt - y.createdAt);
        const next = waiting[0];
        if (!next) return { working: false };
        const active = await activeArtifacts(picked);
        if (!active) return { working: true };
        const { stt, llm } = active.artifacts;
        const have = await engine.installed([stt, llm]);
        if (!have.includes(stt.id) || !have.includes(llm.id)) return { working: true };
        const meeting = next.stage.kind === 'recorded' ? { ...next, tier: active.tier } : next;
        const io: PipelineIO = {
          engine,
          stt,
          llm,
          readUserNotes: (m) => store.readUserNotes(m.id),
          readTranscript: (m) => store.readTranscript(m.id),
          writeTranscript: (m, segments) => store.writeTranscript(m.id, segments),
          writeAiNotes: (m, markdown) => store.writeAiNotes(m.id, markdown),
        };
        const result = await advance(meeting, io);
        await store.saveProgress({ ...result.meeting, progress: result.progress });
        return { working: true };
      } finally {
        ticking = false;
      }
    },

    rows: async (): Promise<MeetingRow[]> => (await store.list()).map(row),

    async detail(id: string): Promise<MeetingDetail> {
      const m = id === '' ? null : await store.load(id);
      if (!m) return MISSING;
      const segments = await store.readTranscript(id);
      return {
        ...row(m),
        found: true,
        audio: m.audio,
        error: m.stage.kind === 'failed' ? m.stage.error : '',
        aiNotes: await store.readAiNotes(id),
        userNotes: await store.readUserNotes(id),
        segments: segments.map((s, i) => ({ id: String(i), at: clock(s.start), text: s.text.trim() })),
      };
    },

    async create(id: string, title: string, audio: string, durationMs: number, userNotes: string, createdAt: number, tier: string): Promise<Reply> {
      if (id === '' || audio === '') return refused('The recording was not saved.');
      await store.create({ id, title, audio, durationS: durationMs / 1000, userNotes, createdAt, tier: isTierId(tier) ? tier : 'lite' });
      return OK;
    },

    saveNotes: async (id: string, text: string): Promise<Reply> => (await store.writeUserNotes(id, text), OK),
    rename: async (id: string, title: string): Promise<Reply> => (await store.rename(id, title), OK),

    async remove(id: string): Promise<Reply> {
      const m = await store.load(id);
      if (m && (m.stage.kind === 'transcribing' || m.stage.kind === 'summarizing')) await engine.cancel(m.stage.job);
      await store.remove(id);
      return OK;
    },

    async retry(id: string): Promise<Reply> {
      const m = await store.load(id);
      if (!m) return refused('That meeting is gone.');
      await store.saveProgress({ ...retry(m), progress: 0 });
      return OK;
    },

    async regenerate(id: string): Promise<Reply> {
      const m = await store.load(id);
      if (!m) return refused('That meeting is gone.');
      await store.saveProgress({ ...regenerate(m), progress: 0 });
      return OK;
    },
  };
}

export type Service = ReturnType<typeof service>;
