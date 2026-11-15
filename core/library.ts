import { isWorking } from './pipeline';
import { meetingStore, type Files, type MeetingStore, type StoredMeeting } from './store';
import type { System } from './system';

/** Where the person asked for meetings to be kept, and whether that place answers now. */
export interface FolderView {
  /** The absolute path of the chosen folder, `''` for app storage. */
  folder: string;
  /** Whether the host can keep meetings in a folder of the person's choosing. */
  supported: boolean;
  reachable: boolean;
  /** Meetings still in app storage that move to the folder once it answers and they are idle. */
  waiting: number;
}

const SETTINGS = 'app:/data/library.json';

const basename = (path: string): string => path.slice(path.lastIndexOf('/') + 1);

async function readFolder(files: Files): Promise<string> {
  try {
    const raw: unknown = JSON.parse(new TextDecoder().decode(await files.readFile(SETTINGS)));
    const folder = typeof raw === 'object' && raw !== null ? (raw as { folder?: unknown }).folder : '';
    return typeof folder === 'string' ? folder : '';
  } catch {
    return '';
  }
}

/**
 * The meetings in app storage and, when the person chose one, in a folder of
 * theirs. It answers as one `MeetingStore`: a meeting is read and written where
 * it lives, and a new one is created in app storage, where the recorder wrote it.
 * `settle` then moves each idle meeting to the folder. A meeting the pipeline is
 * working on stays put until it is done, so the pipeline and a move never write
 * the same meeting. When the folder does not answer (a removed drive, a deleted
 * folder) the app goes on with app storage, and the moves wait for it.
 */
export function library(appFiles: Files, system: System, supported: boolean) {
  const home = meetingStore(appFiles);
  let folder: string | null = null;
  let away: MeetingStore | null = null;
  const where = new Map<string, MeetingStore>();
  let settling: Promise<void> | null = null;

  const chosen = async (): Promise<MeetingStore | null> => {
    if (folder === null) {
      folder = supported ? await readFolder(appFiles) : '';
      away = folder === '' ? null : meetingStore(system.files, folder);
    }
    return away;
  };

  /** The folder's meetings, or null when it does not answer. */
  const folderList = async (): Promise<StoredMeeting[] | null> => {
    const store = await chosen();
    if (!store) return null;
    try {
      await system.files.readdir(store.root);
    } catch {
      return null;
    }
    return store.list();
  };

  const storeOf = async (id: string): Promise<MeetingStore> => {
    const known = where.get(id);
    if (known) return known;
    const store = await chosen();
    if (store && (await store.load(id).catch(() => null))) return store;
    return home;
  };

  async function list(): Promise<StoredMeeting[]> {
    const there = (await folderList()) ?? [];
    const here = await home.list();
    const seen = new Set(there.map((m) => m.id));
    for (const m of there) where.set(m.id, away!);
    for (const m of here) if (!seen.has(m.id)) where.set(m.id, home);
    return [...there, ...here.filter((m) => !seen.has(m.id))].sort((a, b) => b.createdAt - a.createdAt);
  }

  /**
   * Moves idle meetings from app storage to the folder, or back when the person
   * chose app storage again. A meeting already at the destination (a move a crash
   * interrupted after the copy) is only removed from where it was.
   */
  async function move(from: MeetingStore, to: MeetingStore, files: { from: Files }): Promise<void> {
    for (const m of await from.list()) {
      if (isWorking(m)) continue;
      if (await to.load(m.id).catch(() => null)) {
        await files.from.rm(from.dir(m.id)).catch(() => {});
      } else {
        await system.move(from.dir(m.id), to.dir(m.id));
        if (m.audio.startsWith(`${from.dir(m.id)}/`)) await to.relocateAudio(m.id, `${to.dir(m.id)}/${basename(m.audio)}`);
      }
      where.set(m.id, to);
    }
  }

  const settle = (): Promise<void> =>
    (settling ??= (async () => {
      try {
        const store = await chosen();
        if (store && (await folderList()) !== null) {
          await system.files.mkdir(store.root).catch(() => {});
          await move(home, store, { from: appFiles });
        }
      } finally {
        settling = null;
      }
    })());

  const routed = <A extends unknown[], R>(op: (s: MeetingStore) => (id: string, ...rest: A) => Promise<R>) =>
    async (id: string, ...rest: A): Promise<R> => op(await storeOf(id))(id, ...rest);

  const store: MeetingStore = {
    ...home,
    list,
    load: async (id) => (await storeOf(id)).load(id),
    saveProgress: async (m) => (await storeOf(m.id)).saveProgress(m),
    adoptOrphans: () => home.adoptOrphans(),
    create: (m) => {
      where.set(m.id, home);
      return home.create(m);
    },
    rename: routed((s) => s.rename),
    relocateAudio: routed((s) => s.relocateAudio),
    remove: async (id) => {
      await (await storeOf(id)).remove(id);
      where.delete(id);
    },
    readUserNotes: routed((s) => s.readUserNotes),
    writeUserNotes: routed((s) => s.writeUserNotes),
    readAiNotes: routed((s) => s.readAiNotes),
    writeAiNotes: routed((s) => s.writeAiNotes),
    readExtra: routed((s) => s.readExtra),
    writeExtra: routed((s) => s.writeExtra),
    readTranscript: routed((s) => s.readTranscript),
    writeTranscript: routed((s) => s.writeTranscript),
  };

  return {
    store,
    settle,
    /** Where new and imported meetings go: the folder when it answers, else app storage. */
    async target(): Promise<MeetingStore> {
      return (await folderList()) !== null ? away! : home;
    },
    async view(): Promise<FolderView> {
      const store = await chosen();
      const reachable = store ? (await folderList()) !== null : true;
      const waiting = store ? (await home.list()).length : 0;
      return { folder: folder ?? '', supported, reachable, waiting };
    },
    /**
     * Records the person's choice and moves what can move now. Choosing app storage
     * again brings the folder's meetings back, if it answers.
     */
    async choose(path: string): Promise<void> {
      if (!supported) throw new Error('This device keeps meetings in app storage only.');
      const previous = await chosen();
      await appFiles.atomicWriteFile(SETTINGS, new TextEncoder().encode(JSON.stringify({ folder: path })));
      folder = path;
      away = path === '' ? null : meetingStore(system.files, path);
      if (path === '' && previous) {
        try {
          await system.files.readdir(previous.root);
          await move(previous, home, { from: system.files });
        } catch {
          // The old folder is gone; its meetings stay there for when it comes back.
        }
      }
      await settle();
    },
  };
}

export type Library = ReturnType<typeof library>;
