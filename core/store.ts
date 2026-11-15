import type { Meeting, Segment, Stage, TierId } from './types';
import { isTierId } from './types';

/** The part of the host's file system the store uses. Paths are `app:/` paths. */
export interface Files {
  readFile(path: string): Promise<ArrayBuffer>;
  atomicWriteFile(path: string, data: Uint8Array): Promise<void>;
  readdir(path: string): Promise<string[]>;
  mkdir(path: string): Promise<void>;
  rm(path: string): Promise<void>;
}

export const MEETINGS_DIR = 'app:/data/meetings';

/**
 * A meeting is a folder. The person's actions write `meeting.json` and
 * `notes.md`; only the pipeline writes `stage.json`, `transcript.json` and
 * `ai-notes.md`. Two writers never share a file, so a notes save cannot
 * overwrite a pipeline step that lands at the same moment.
 */
const layout = (root: string) => {
  const meetingDir = (id: string): string => `${root}/${id}`;
  const paths = (id: string) => ({
    identity: `${meetingDir(id)}/meeting.json`,
    stage: `${meetingDir(id)}/stage.json`,
    userNotes: `${meetingDir(id)}/notes.md`,
    transcript: `${meetingDir(id)}/transcript.json`,
    aiNotes: `${meetingDir(id)}/ai-notes.md`,
  });
  /** A file an app adds to a meeting's folder: a plain name the store does not own. */
  const extraPath = (id: string, name: string): string => {
    if (!/^[a-z0-9][a-z0-9.-]*$/.test(name) || OWNED.has(name) || name.startsWith('audio')) {
      throw new Error(`"${name}" is not a file an app may add to a meeting.`);
    }
    return `${meetingDir(id)}/${name}`;
  };
  return { meetingDir, paths, extraPath };
};

const OWNED = new Set(['meeting.json', 'stage.json', 'notes.md', 'transcript.json', 'ai-notes.md']);

interface Identity {
  id: string;
  title: string;
  createdAt: number;
  durationS: number;
  audio: string;
  tier: TierId;
}

interface Progress {
  stage: Stage;
  attempt: number;
  progress: number;
  suggestedTitle: string;
}

export interface StoredMeeting extends Meeting {
  progress: number;
}

const isMissing = (e: unknown): boolean => {
  const code = typeof e === 'object' && e !== null && 'code' in e ? (e as { code: unknown }).code : undefined;
  // 'bake' is Exact's code for storage at build time, when no file exists. ENOTDIR is a stray file
  // in the meetings folder being read as if it were a meeting's folder.
  return code === 'ENOENT' || code === 'ENOTDIR' || code === 'bake';
};

async function readText(files: Files, path: string): Promise<string | null> {
  try {
    return new TextDecoder().decode(await files.readFile(path));
  } catch (e) {
    if (isMissing(e)) return null;
    throw e;
  }
}

const writeText = (files: Files, path: string, text: string): Promise<void> =>
  files.atomicWriteFile(path, new TextEncoder().encode(text));

function parseJson(text: string | null): unknown {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const obj = (raw: unknown): Record<string, unknown> | null =>
  typeof raw === 'object' && raw !== null && !Array.isArray(raw) ? (raw as Record<string, unknown>) : null;
const str = (v: unknown): string => (typeof v === 'string' ? v : '');
const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

function parseIdentity(raw: unknown): Identity | null {
  const r = obj(raw);
  if (!r || typeof r.id !== 'string' || r.id === '') return null;
  return {
    id: r.id,
    title: str(r.title),
    createdAt: num(r.createdAt),
    durationS: num(r.durationS),
    audio: str(r.audio),
    tier: isTierId(r.tier) ? r.tier : 'lite',
  };
}

function parseStage(raw: unknown): Stage {
  const r = obj(raw);
  switch (r?.kind) {
    case 'transcribing':
      return { kind: 'transcribing', job: str(r.job) };
    case 'summarizing':
      return {
        kind: 'summarizing',
        job: str(r.job),
        step: num(r.step),
        steps: num(r.steps),
        partials: Array.isArray(r.partials) ? r.partials.map(str) : [],
      };
    case 'done':
      return { kind: 'done' };
    case 'failed':
      return { kind: 'failed', during: r.during === 'summarizing' ? 'summarizing' : 'transcribing', error: str(r.error) };
    default:
      return { kind: 'recorded' };
  }
}

function parseProgress(raw: unknown): Progress {
  const r = obj(raw) ?? {};
  return { stage: parseStage(r.stage), attempt: num(r.attempt), progress: num(r.progress), suggestedTitle: str(r.suggestedTitle) };
}

function parseSegments(raw: unknown): Segment[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    const r = obj(item);
    return r ? [{ start: num(r.start), end: num(r.end), text: str(r.text) }] : [];
  });
}

export interface NewMeeting {
  id: string;
  title: string;
  createdAt: number;
  durationS: number;
  audio: string;
  tier: TierId;
  userNotes: string;
}

/** The meetings under `root`: app storage by default, or a folder the person chose. */
export function meetingStore(files: Files, root: string = MEETINGS_DIR) {
  const { meetingDir, paths, extraPath } = layout(root);

  const load = async (id: string): Promise<StoredMeeting | null> => {
    const p = paths(id);
    const identity = parseIdentity(parseJson(await readText(files, p.identity)));
    if (!identity) return null;
    const progress = parseProgress(parseJson(await readText(files, p.stage)));
    return { ...identity, ...progress };
  };

  const saveProgress = (m: StoredMeeting): Promise<void> =>
    writeText(
      files,
      paths(m.id).stage,
      JSON.stringify({ stage: m.stage, attempt: m.attempt, progress: m.progress, suggestedTitle: m.suggestedTitle } satisfies Progress),
    );

  return {
    load,
    saveProgress,

    /** Every meeting, newest first. A folder without a readable `meeting.json` is skipped. */
    async list(): Promise<StoredMeeting[]> {
      let ids: string[];
      try {
        ids = await files.readdir(root);
      } catch (e) {
        if (isMissing(e)) return [];
        throw e;
      }
      const meetings = await Promise.all(ids.map(load));
      return meetings.filter((m): m is StoredMeeting => m !== null).sort((a, b) => b.createdAt - a.createdAt);
    },

    /**
     * Folders that hold a recording but no `meeting.json`: the app quit, or the save failed,
     * before the recording became a meeting. Each is given a record so the person can see it.
     */
    async adoptOrphans(): Promise<void> {
      let ids: string[];
      try {
        ids = await files.readdir(root);
      } catch (e) {
        if (isMissing(e)) return;
        throw e;
      }
      for (const id of ids) {
        if ((await readText(files, paths(id).identity)) !== null) continue;
        const entries = await files.readdir(meetingDir(id)).catch(() => []);
        const audio = entries.find((name) => name.startsWith('audio'));
        if (!audio) continue;
        const createdAt = Number(id.replace(/^m/, ''));
        const identity: Identity = {
          id, title: 'Recovered recording', createdAt: Number.isFinite(createdAt) ? createdAt : 0,
          durationS: 0, audio: `${meetingDir(id)}/${audio}`, tier: 'lite',
        };
        await writeText(files, paths(id).identity, JSON.stringify(identity));
      }
    },

    async create(m: NewMeeting): Promise<void> {
      const p = paths(m.id);
      // mkdir refuses a folder that exists, and the recorder has usually made this one already.
      await files.mkdir(root).catch(() => {});
      await files.mkdir(meetingDir(m.id)).catch(() => {});
      await writeText(files, p.userNotes, m.userNotes);
      const identity: Identity = { id: m.id, title: m.title, createdAt: m.createdAt, durationS: m.durationS, audio: m.audio, tier: m.tier };
      await writeText(files, p.identity, JSON.stringify(identity));
    },

    async rename(id: string, title: string): Promise<void> {
      const identity = parseIdentity(parseJson(await readText(files, paths(id).identity)));
      if (identity) await writeText(files, paths(id).identity, JSON.stringify({ ...identity, title }));
    },

    /** Points a moved meeting at its recording's new path. */
    async relocateAudio(id: string, audio: string): Promise<void> {
      const identity = parseIdentity(parseJson(await readText(files, paths(id).identity)));
      if (identity && identity.audio !== audio) await writeText(files, paths(id).identity, JSON.stringify({ ...identity, audio }));
    },

    root,
    dir: meetingDir,
    async mkdirMeeting(id: string): Promise<void> {
      await files.mkdir(root).catch(() => {});
      await files.mkdir(meetingDir(id)).catch(() => {});
    },

    remove: (id: string): Promise<void> => files.rm(meetingDir(id)),

    readUserNotes: async (id: string): Promise<string> => (await readText(files, paths(id).userNotes)) ?? '',
    writeUserNotes: (id: string, text: string): Promise<void> => writeText(files, paths(id).userNotes, text),
    readAiNotes: async (id: string): Promise<string> => (await readText(files, paths(id).aiNotes)) ?? '',
    writeAiNotes: (id: string, text: string): Promise<void> => writeText(files, paths(id).aiNotes, text),
    /** An app's own file in the meeting's folder, `''` when it has none. */
    readExtra: async (id: string, name: string): Promise<string> => (await readText(files, extraPath(id, name))) ?? '',
    writeExtra: (id: string, name: string, text: string): Promise<void> => writeText(files, extraPath(id, name), text),
    readTranscript: async (id: string): Promise<Segment[]> => parseSegments(parseJson(await readText(files, paths(id).transcript))),
    writeTranscript: (id: string, segments: Segment[]): Promise<void> => writeText(files, paths(id).transcript, JSON.stringify(segments)),
  };
}

export type MeetingStore = ReturnType<typeof meetingStore>;
