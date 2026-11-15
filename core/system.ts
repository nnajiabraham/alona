import type { Files } from './store';

/**
 * What the operating system offers Alona beyond inference: a folder outside the
 * app's storage, meeting detection and system audio capture. It is a protocol of
 * its own, not part of `engine.ts`, because three engines answer inference (Apple,
 * the web Worker and the demo engine) while only the macOS module answers this, and
 * every other host gets `NO_SYSTEM`. An engine never has to answer an op it cannot.
 */

export type MeetingApp = 'zoom' | 'meet' | 'teams';

export const MEETING_APPS: Record<MeetingApp, string> = { zoom: 'Zoom', meet: 'Google Meet', teams: 'Microsoft Teams' };

/** A call the module believes is happening now. `key` changes when the call does. */
export interface Detected {
  app: MeetingApp;
  title: string;
  key: string;
}

/**
 * Whether system audio was heard. `unknown` before any recording, `silent` when a
 * recording's tap delivered nothing but zeros, which is what macOS gives an app
 * the person has not allowed to record system audio.
 */
export type CaptureHealth = 'unknown' | 'heard' | 'silent';

export interface SystemFacts {
  /** A folder outside app storage can be read and written by absolute path. */
  folders: boolean;
  detection: boolean;
  capture: boolean;
  /** Where the Swift app kept meetings: its saved setting, else its default. `''` when unknown. */
  legacyFolder: string;
  /** Whether Accessibility is granted, so a muted Zoom call is still found. */
  accessibility: boolean;
}

export interface CaptureResult {
  /** The system audio file, `''` when nothing was captured. */
  path: string;
  /** Milliseconds after the microphone recording started that the system audio did. */
  offsetMs: number;
  health: CaptureHealth;
}

export interface System {
  facts(): Promise<SystemFacts>;
  files: Files;
  /** Copies a meeting folder to `to` and then removes `from`, as one step a crash cannot split. */
  move(from: string, to: string): Promise<void>;
  /** Copies one file, which may be larger than a JavaScript read allows. */
  copy(from: string, to: string): Promise<void>;
  /** A recording's length in seconds and the file's creation time, each 0 when unknown. */
  audioInfo(path: string): Promise<{ seconds: number; createdMs: number }>;
  /** The call happening now, or null. Asks again when it changes, under `native.watch('meeting')`. */
  detected(enabled: boolean): Promise<Detected | null>;
  startCapture(path: string): Promise<boolean>;
  stopCapture(): Promise<CaptureResult>;
  /** Writes `out`: the microphone and system recordings mixed, in fixed-size chunks. */
  mix(mic: string, system: string, offsetMs: number, out: string): Promise<void>;
}

const refuse = (): never => {
  throw Object.assign(new Error('This device has no folder access.'), { code: 'unsupported' });
};

export const NO_SYSTEM: System = {
  facts: async () => ({ folders: false, detection: false, capture: false, legacyFolder: '', accessibility: false }),
  files: { readFile: refuse, atomicWriteFile: refuse, readdir: refuse, mkdir: refuse, rm: refuse },
  move: refuse,
  copy: refuse,
  audioInfo: async () => ({ seconds: 0, createdMs: 0 }),
  detected: async () => null,
  startCapture: async () => false,
  stopCapture: async () => ({ path: '', offsetMs: 0, health: 'unknown' }),
  mix: refuse,
};

/** The part of Exact's native module this seam uses. */
export interface SystemNative {
  later(request: Record<string, unknown>): Promise<Record<string, unknown>>;
  watch?(topic: string): void;
}

const str = (v: unknown): string => (typeof v === 'string' ? v : '');
const isApp = (v: unknown): v is MeetingApp => v === 'zoom' || v === 'meet' || v === 'teams';

/** A reply's `error` is a file system code such as `ENOENT`, raised as the store expects one. */
async function ask(native: SystemNative, request: Record<string, unknown>): Promise<Record<string, unknown>> {
  const reply = await native.later(request);
  const code = str(reply.error);
  if (code !== '') throw Object.assign(new Error(str(reply.message) || code), { code });
  return reply;
}

/** The seam over the macOS module, which answers ops whose names start `sys.`. */
export function nativeSystem(native: SystemNative): System {
  const files: Files = {
    readFile: async (path) => new TextEncoder().encode(str((await ask(native, { op: 'sys.read', path })).text)).buffer as ArrayBuffer,
    atomicWriteFile: async (path, data) => void (await ask(native, { op: 'sys.write', path, text: new TextDecoder().decode(data) })),
    readdir: async (path) => {
      const names = (await ask(native, { op: 'sys.list', path })).names;
      return Array.isArray(names) ? names.map(str) : [];
    },
    mkdir: async (path) => void (await ask(native, { op: 'sys.mkdir', path })),
    rm: async (path) => void (await ask(native, { op: 'sys.rm', path })),
  };
  return {
    async facts() {
      const r = await native.later({ op: 'sys.facts' }).catch(() => null);
      if (!r) return NO_SYSTEM.facts();
      return {
        folders: r.folders === true,
        detection: r.detection === true,
        capture: r.capture === true,
        legacyFolder: str(r.legacyFolder),
        accessibility: r.accessibility === true,
      };
    },
    files,
    move: async (from, to) => void (await ask(native, { op: 'sys.move', from, to })),
    copy: async (from, to) => void (await ask(native, { op: 'sys.copy', from, to })),
    audioInfo: async (path) => {
      const r = (await native.later({ op: 'sys.audioInfo', path }).catch(() => ({}))) as Record<string, unknown>;
      const n = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
      return { seconds: n(r.seconds), createdMs: n(r.createdMs) };
    },
    async detected(enabled) {
      native.watch?.('meeting');
      const r = await native.later({ op: 'sys.detect', enabled }).catch(() => null);
      if (!r || !isApp(r.app)) return null;
      const title = str(r.title) || MEETING_APPS[r.app];
      return { app: r.app, title, key: `${r.app}|${title}` };
    },
    startCapture: async (path) => (await native.later({ op: 'sys.captureStart', path }).catch(() => ({}) as Record<string, unknown>)).ok === true,
    async stopCapture() {
      const r = await native.later({ op: 'sys.captureStop' }).catch(() => ({}) as Record<string, unknown>);
      const health = r.health === 'heard' || r.health === 'silent' ? r.health : 'unknown';
      return { path: str(r.path), offsetMs: typeof r.offsetMs === 'number' ? r.offsetMs : 0, health };
    },
    mix: async (mic, system, offsetMs, out) => void (await ask(native, { op: 'sys.mix', mic, system, offsetMs, out })),
  };
}
