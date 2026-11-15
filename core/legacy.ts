import type { MeetingStore } from './store';
import type { System } from './system';
import type { Segment } from './types';

/**
 * Meetings the Swift app recorded. Its folder layout is `yyyy-MM-dd_HHmm_<slug>/`
 * holding `title.txt`, `recording.wav` (system audio left, microphone right) or
 * `recording-mono.wav`, `notes.md` (or the autosave `notes.tmp` a crash left),
 * `transcript.json` and `summary.md` (docs/rewrite/legacy-inventory.md §4.1).
 * `summary.md` is not imported: the Swift app only ever wrote a placeholder there.
 */
export interface LegacyRecording {
  /** The source folder's name, which is also what the import is keyed by. */
  name: string;
  /** The meeting id an import gives it. The same folder always gets the same id. */
  id: string;
  title: string;
  /** Epoch ms from the folder name, read in the device's time zone. */
  createdAt: number;
  /** The recording's file name in the source folder. */
  audio: string;
  hasTranscript: boolean;
  notes: 'notes.md' | 'notes.tmp' | '';
  imported: boolean;
}

const LEGACY_NAME = /^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(?:_(.*))?$/;

/** Epoch ms of a Swift folder name's local time, given the zone's offset from UTC in minutes. 0 when it is not one. */
export function legacyTime(name: string, utcOffsetMinutes: number): number {
  const m = LEGACY_NAME.exec(name);
  if (!m) return 0;
  const [y, mo, d, h, mi] = m.slice(1, 6).map(Number);
  const utc = Date.UTC(y, mo - 1, d, h, mi);
  return Number.isFinite(utc) ? utc - utcOffsetMinutes * 60_000 : 0;
}

/** FNV-1a, enough to tell two folder names apart once the id's characters are narrowed. */
function hash(text: string): string {
  let h = 0x811c9dc5;
  for (const c of text) {
    h ^= c.codePointAt(0)!;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(36);
}

/** The meeting id of a Swift folder: stable, so importing twice finds the first import. */
export function legacyId(name: string): string {
  const narrowed = name.replace(/[^A-Za-z0-9_-]+/g, '-').slice(0, 48);
  return `swift-${narrowed}-${hash(name)}`;
}

/** The title the Swift app showed: `title.txt`, else the folder's slug. */
export function legacyTitle(titleTxt: string | null, name: string): string {
  const saved = (titleTxt ?? '').trim();
  if (saved !== '') return saved;
  const slug = LEGACY_NAME.exec(name)?.[6] ?? name;
  return slug.replace(/-+/g, ' ').trim();
}

export function parseLegacyTranscript(text: string | null): Segment[] {
  if (text === null) return [];
  try {
    const raw: unknown = JSON.parse(text);
    if (!Array.isArray(raw)) return [];
    return raw.flatMap((r) => {
      if (typeof r !== 'object' || r === null) return [];
      const { start, end, text: t } = r as Record<string, unknown>;
      return typeof start === 'number' && typeof end === 'number' && typeof t === 'string' ? [{ start, end, text: t }] : [];
    });
  } catch {
    return [];
  }
}

async function readText(system: System, path: string): Promise<string | null> {
  try {
    return new TextDecoder().decode(await system.files.readFile(path));
  } catch {
    return null;
  }
}

/** Every Swift recording in `folder`, newest first, each marked when `exists` already has its id. */
export async function scanLegacy(system: System, folder: string, utcOffsetMinutes: number, exists: (id: string) => boolean): Promise<LegacyRecording[]> {
  let names: string[];
  try {
    names = await system.files.readdir(folder);
  } catch {
    return [];
  }
  const found: LegacyRecording[] = [];
  for (const name of names) {
    if (name.startsWith('.')) continue;
    const entries = await system.files.readdir(`${folder}/${name}`).catch(() => [] as string[]);
    const audio = ['recording.wav', 'recording-mono.wav'].find((a) => entries.includes(a));
    if (!audio) continue;
    const id = legacyId(name);
    found.push({
      name,
      id,
      title: legacyTitle(entries.includes('title.txt') ? await readText(system, `${folder}/${name}/title.txt`) : null, name),
      createdAt: legacyTime(name, utcOffsetMinutes),
      audio,
      hasTranscript: entries.includes('transcript.json'),
      notes: entries.includes('notes.md') ? 'notes.md' : entries.includes('notes.tmp') ? 'notes.tmp' : '',
      imported: exists(id),
    });
  }
  return found.sort((a, b) => b.createdAt - a.createdAt);
}

/**
 * Imports one Swift recording into `store`. It only reads the source folder. The
 * meeting's record is written last, so an import a crash cut short is not a
 * meeting yet and runs again in full. A meeting that had a transcript arrives
 * done, with that transcript; one without arrives recorded, so the pipeline
 * transcribes it. Either can be transcribed again and have notes written.
 */
export async function importLegacy(system: System, folder: string, rec: LegacyRecording, store: MeetingStore): Promise<void> {
  const src = `${folder}/${rec.name}`;
  const dir = store.dir(rec.id);
  await store.mkdirMeeting(rec.id);
  const audio = `${dir}/audio.wav`;
  await system.copy(`${src}/${rec.audio}`, audio);
  const info = await system.audioInfo(audio);
  const segments = rec.hasTranscript ? parseLegacyTranscript(await readText(system, `${src}/transcript.json`)) : [];
  if (segments.length > 0) await store.writeTranscript(rec.id, segments);
  const notes = rec.notes === '' ? '' : ((await readText(system, `${src}/${rec.notes}`)) ?? '');
  await store.saveProgress({
    id: rec.id, title: rec.title, createdAt: rec.createdAt, durationS: info.seconds, audio, tier: 'lite',
    stage: segments.length > 0 ? { kind: 'done' } : { kind: 'recorded' }, attempt: 0, progress: 0, suggestedTitle: '',
  });
  await store.create({
    id: rec.id, title: rec.title, createdAt: rec.createdAt || info.createdMs, durationS: info.seconds, audio, tier: 'lite', userNotes: notes,
  });
}
