import { importLegacy, scanLegacy, type LegacyRecording } from './legacy';
import type { Library } from './library';
import type { Reply } from './service';
import type { CaptureHealth, Detected, System } from './system';

/** What Settings shows about the folder, the Swift app's recordings, detection and system audio. */
export interface DeskView {
  /** The macOS module answers: the menu bar item and detection are shown. */
  mac: boolean;
  foldersSupported: boolean;
  folder: string;
  folderReachable: boolean;
  waiting: number;
  legacyFolder: string;
  /** Whether the folder was read. It is read only once the person asks, because macOS asks them first for ~/Documents. */
  legacyLooked: boolean;
  legacyCount: number;
  legacyNew: number;
  detectionSupported: boolean;
  captureSupported: boolean;
  captureHealth: CaptureHealth;
  accessibility: boolean;
}

export interface DetectionView {
  found: boolean;
  app: string;
  title: string;
  key: string;
}

const OK: Reply = { ok: true, error: '' };
const NONE: DetectionView = { found: false, app: '', title: '', key: '' };

const message = (e: unknown): string => (e instanceof Error ? e.message : String(e));

/**
 * The desktop operations that sit beside the meeting service: the meetings
 * folder, importing the Swift app's recordings, meeting detection and system
 * audio. Every one degrades to "not on this device" through `NO_SYSTEM`.
 */
export function desk(system: System, lib: Library, resolve: (chosen: string) => Promise<string>) {
  let health: CaptureHealth = 'unknown';
  let capturing = false;
  let picked = '';

  const legacyFolder = async (): Promise<string> => picked || (await system.facts()).legacyFolder;

  const legacy = async (utcOffset: number): Promise<{ folder: string; found: LegacyRecording[] }> => {
    const folder = await legacyFolder();
    if (folder === '') return { folder, found: [] };
    const ids = new Set((await lib.store.list()).map((m) => m.id));
    return { folder, found: await scanLegacy(system, folder, utcOffset, (id) => ids.has(id)) };
  };

  return {
    /** `look`: the person asked to look for the Swift app's recordings. */
    async view(utcOffset: number, look: boolean): Promise<DeskView> {
      const facts = await system.facts();
      const folder = await lib.view();
      const looked = facts.folders && (look || picked !== '');
      const { folder: lf, found } = looked ? await legacy(utcOffset) : { folder: facts.folders ? facts.legacyFolder : '', found: [] };
      return {
        mac: facts.folders,
        foldersSupported: folder.supported,
        folder: folder.folder,
        folderReachable: folder.reachable,
        waiting: folder.waiting,
        legacyFolder: lf,
        legacyLooked: looked,
        legacyCount: found.length,
        legacyNew: found.filter((r) => !r.imported).length,
        detectionSupported: facts.detection,
        captureSupported: facts.capture,
        captureHealth: health,
        accessibility: facts.accessibility,
      };
    },

    /** `chosen` is what the folder picker answered, or `''` for app storage. */
    async chooseFolder(chosen: string): Promise<Reply> {
      try {
        await lib.choose(chosen === '' ? '' : await resolve(chosen));
        return OK;
      } catch (e) {
        return { ok: false, error: message(e) };
      }
    },

    /** Points the import at a folder the person picked, for a Swift app that saved somewhere else. */
    async pickLegacy(chosen: string): Promise<Reply> {
      try {
        picked = await resolve(chosen);
        return OK;
      } catch (e) {
        return { ok: false, error: message(e) };
      }
    },

    /** Imports every Swift recording not imported yet. Running it again imports nothing twice. */
    async importAll(utcOffset: number): Promise<Reply> {
      const { folder, found } = await legacy(utcOffset);
      const target = await lib.target();
      try {
        for (const rec of found) if (!rec.imported) await importLegacy(system, folder, rec, target);
        return OK;
      } catch (e) {
        return { ok: false, error: `Import stopped: ${message(e)}` };
      }
    },

    /** Off also tells the module to stop listening. */
    async detection(enabled: boolean): Promise<DetectionView> {
      const d: Detected | null = await system.detected(enabled);
      return enabled && d ? { found: true, ...d } : NONE;
    },

    async startCapture(id: string, on: boolean): Promise<Reply> {
      if (!on || !(await system.facts()).capture) return OK;
      capturing = await system.startCapture(`app:/data/meetings/${id}/system.m4a`);
      return OK;
    },

    /**
     * The recording a new meeting keeps: the microphone's alone, or mixed with the
     * system audio when that was captured. A failed mix keeps the microphone's, so
     * stopping never loses the take.
     */
    async finish(id: string, mic: string): Promise<string> {
      if (!capturing) return mic;
      capturing = false;
      const sys = await system.stopCapture();
      health = sys.health;
      if (sys.path === '') return mic;
      const out = `app:/data/meetings/${id}/audio-mixed.m4a`;
      try {
        await system.mix(mic, sys.path, sys.offsetMs, out);
        return out;
      } catch {
        return mic;
      }
    },
  };
}

export type Desk = ReturnType<typeof desk>;
