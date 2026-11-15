import { describe, expect, test } from 'bun:test';
import { desk } from './desk';
import { memoryFiles } from './fixtures/memory-files';
import { legacyId, legacyTime, legacyTitle } from './legacy';
import { library } from './library';
import { meetingStore, type Files } from './store';
import { nativeSystem, NO_SYSTEM, type System } from './system';

const text = (s: string) => new TextEncoder().encode(s);
const read = async (files: Files, path: string) => new TextDecoder().decode(await files.readFile(path));

/** One in-memory disk for app storage and absolute paths, with a folder that can be unplugged. */
function disk() {
  const files = memoryFiles();
  let unplugged = '';
  const dirs = new Set<string>();
  let documentsReads = 0;
  const gone = (path: string) => {
    if (path.startsWith('/Users/me/Documents')) documentsReads += 1;
    return unplugged !== '' && path.startsWith(unplugged);
  };
  const enoent = () => Object.assign(new Error('gone'), { code: 'ENOENT' });
  const guarded: Files = {
    readFile: async (p) => (gone(p) ? Promise.reject(enoent()) : files.readFile(p)),
    atomicWriteFile: async (p, d) => (gone(p) ? Promise.reject(enoent()) : files.atomicWriteFile(p, d)),
    readdir: async (p) => {
      if (gone(p)) throw enoent();
      const names = await files.readdir(p);
      if (names.length === 0 && p.startsWith('/') && !dirs.has(p)) throw enoent();
      return names;
    },
    mkdir: async (p) => {
      if (gone(p)) throw enoent();
      dirs.add(p);
    },
    rm: async (p) => (gone(p) ? Promise.reject(enoent()) : files.rm(p)),
  };
  const copyTree = async (from: string, to: string) => {
    for (const p of files.paths().filter((k) => k.startsWith(`${from}/`) || k === from)) {
      await files.atomicWriteFile(to + p.slice(from.length), new Uint8Array(await files.readFile(p)));
    }
  };
  const system: System = {
    ...NO_SYSTEM,
    facts: async () => ({ folders: true, detection: true, capture: false, legacyFolder: '/Users/me/Documents/Alona', accessibility: false }),
    files: guarded,
    move: async (from, to) => {
      if (gone(to)) throw enoent();
      await copyTree(from, to);
      await files.rm(from);
    },
    copy: async (from, to) => copyTree(from, to),
    audioInfo: async () => ({ seconds: 61, createdMs: 0 }),
  };
  for (const folder of ['/Users/me/Meetings', '/Volumes/USB/Meetings']) dirs.add(folder);
  return { files, system, documentsReads: () => documentsReads, unplug: (path: string) => void (unplugged = path), plug: () => void (unplugged = '') };
}

const meeting = (id: string, createdAt: number) => ({
  id, title: id, createdAt, durationS: 10, audio: `app:/data/meetings/${id}/audio.m4a`, tier: 'lite' as const, userNotes: `notes of ${id}`,
});

async function recorded(files: Files, id: string, createdAt: number, done = true) {
  const store = meetingStore(files);
  await files.atomicWriteFile(`app:/data/meetings/${id}/audio.m4a`, text('AUDIO'));
  await store.create(meeting(id, createdAt));
  if (done) {
    const m = (await store.load(id))!;
    await store.saveProgress({ ...m, stage: { kind: 'done' } });
  }
}

describe('meetings folder', () => {
  test('choosing a folder moves idle meetings there with their recordings, and they read back the same', async () => {
    const d = disk();
    await recorded(d.files, 'm1', 1);
    await recorded(d.files, 'm2', 2);
    const lib = library(d.files, d.system, true);
    await lib.choose('/Users/me/Meetings');
    expect(d.files.paths().filter((p) => p.startsWith('app:/data/meetings'))).toEqual([]);
    const listed = await lib.store.list();
    expect(listed.map((m) => m.id)).toEqual(['m2', 'm1']);
    expect(listed[0].audio).toBe('/Users/me/Meetings/m2/audio.m4a');
    expect(await read(d.files, '/Users/me/Meetings/m2/audio.m4a')).toBe('AUDIO');
    expect(await lib.store.readUserNotes('m1')).toBe('notes of m1');
    expect(await read(d.files, 'app:/data/library.json')).toBe(JSON.stringify({ folder: '/Users/me/Meetings' }));
  });

  test('a meeting the pipeline is working on stays in app storage until it is done', async () => {
    const d = disk();
    await recorded(d.files, 'busy', 1, false);
    const lib = library(d.files, d.system, true);
    await lib.choose('/Users/me/Meetings');
    expect((await lib.view()).waiting).toBe(1);
    expect((await lib.store.load('busy'))!.audio).toBe('app:/data/meetings/busy/audio.m4a');
    const m = (await lib.store.load('busy'))!;
    await lib.store.saveProgress({ ...m, stage: { kind: 'done' } });
    await lib.settle();
    expect((await lib.store.load('busy'))!.audio).toBe('/Users/me/Meetings/busy/audio.m4a');
    expect((await lib.view()).waiting).toBe(0);
  });

  test('when the folder disappears the app keeps working from app storage, and moves new meetings once it is back', async () => {
    const d = disk();
    await recorded(d.files, 'old', 1);
    const lib = library(d.files, d.system, true);
    await lib.choose('/Volumes/USB/Meetings');
    d.unplug('/Volumes/USB');
    expect((await lib.view()).reachable).toBe(false);
    expect(await lib.store.list()).toEqual([]);
    await recorded(d.files, 'new', 2);
    await lib.settle();
    expect((await lib.store.list()).map((m) => m.id)).toEqual(['new']);
    expect(await lib.target()).not.toBe(null);
    d.plug();
    await lib.settle();
    expect((await lib.store.list()).map((m) => [m.id, m.audio])).toEqual([
      ['new', '/Volumes/USB/Meetings/new/audio.m4a'],
      ['old', '/Volumes/USB/Meetings/old/audio.m4a'],
    ]);
  });

  test('a move a crash cut short after the copy only removes the leftover copy', async () => {
    const d = disk();
    await recorded(d.files, 'm1', 1);
    const lib = library(d.files, d.system, true);
    await lib.choose('/Users/me/Meetings');
    await recorded(d.files, 'm1', 1);
    await lib.settle();
    expect((await lib.store.list()).length).toBe(1);
    expect(d.files.paths().filter((p) => p.startsWith('app:/data/meetings'))).toEqual([]);
  });

  test('choosing app storage again brings the meetings back', async () => {
    const d = disk();
    await recorded(d.files, 'm1', 1);
    const lib = library(d.files, d.system, true);
    await lib.choose('/Users/me/Meetings');
    await lib.choose('');
    const [m] = await lib.store.list();
    expect(m.audio).toBe('app:/data/meetings/m1/audio.m4a');
    expect(d.files.paths().some((p) => p.startsWith('/Users/me/Meetings/m1'))).toBe(false);
  });

  test('a host without folder access refuses a choice and lists app storage', async () => {
    const d = disk();
    await recorded(d.files, 'm1', 1);
    const lib = library(d.files, d.system, false);
    await expect(lib.choose('/x')).rejects.toThrow('app storage only');
    expect((await lib.view()).supported).toBe(false);
    expect((await lib.store.list()).length).toBe(1);
  });
});

const SWIFT = '/Users/me/Documents/Alona';

async function swiftMeeting(files: Files, name: string, parts: Record<string, string>) {
  for (const [file, body] of Object.entries(parts)) await files.atomicWriteFile(`${SWIFT}/${name}/${file}`, text(body));
}

describe('Swift app migration', () => {
  test('a folder name is read as local time in the device zone', () => {
    expect(legacyTime('2025-11-27_1030_Product-Sync', 60)).toBe(Date.UTC(2025, 10, 27, 9, 30));
    expect(legacyTime('not-a-meeting', 0)).toBe(0);
  });

  test('ids are stable, safe and distinct for names that narrow alike', () => {
    expect(legacyId('2025-11-27_1030_Café')).toBe(legacyId('2025-11-27_1030_Café'));
    expect(legacyId('2025-11-27_1030_Café')).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(legacyId('2025-11-27_1030_Caf€')).not.toBe(legacyId('2025-11-27_1030_Café'));
  });

  test('the title is title.txt, else the folder slug', () => {
    expect(legacyTitle(' Weekly sync \n', '2025-11-27_1030_x')).toBe('Weekly sync');
    expect(legacyTitle(null, '2025-11-27_1030_Product-Sync')).toBe('Product Sync');
  });

  test('import brings audio, notes, transcript, title and date, is idempotent, and leaves the source untouched', async () => {
    const d = disk();
    await swiftMeeting(d.files, '2025-11-27_1030_Product-Sync', {
      'title.txt': 'Product sync', 'recording.wav': 'WAV', 'recording-mono.wav': 'MONO', 'notes.md': '• ask about pricing',
      'transcript.json': JSON.stringify([{ start: 0, end: 2.5, text: 'Hello all' }]), 'summary.md': 'placeholder',
    });
    await swiftMeeting(d.files, '2025-11-28_0900_Crash', { 'recording-mono.wav': 'MONO', 'notes.tmp': 'draft before crash' });
    await d.files.atomicWriteFile(`${SWIFT}/stray.txt/x`, text('not a meeting'));
    const before = d.files.paths().filter((p) => p.startsWith(SWIFT)).map((p) => p);
    const lib = library(d.files, d.system, true);
    const tools = desk(d.system, lib, async (p) => p);

    expect(await tools.view(0, false)).toMatchObject({ legacyLooked: false, legacyCount: 0, legacyFolder: SWIFT });
    expect(d.documentsReads()).toBe(0);
    expect(await tools.view(0, true)).toMatchObject({ legacyLooked: true, legacyCount: 2, legacyNew: 2, legacyFolder: SWIFT });
    expect(await tools.importAll(0)).toEqual({ ok: true, error: '' });
    expect(await tools.view(0, true)).toMatchObject({ legacyCount: 2, legacyNew: 0 });
    expect(await tools.importAll(0)).toEqual({ ok: true, error: '' });

    const listed = await lib.store.list();
    expect(listed.map((m) => [m.title, m.createdAt, m.stage.kind, m.durationS])).toEqual([
      ['Crash', Date.UTC(2025, 10, 28, 9, 0), 'recorded', 61],
      ['Product sync', Date.UTC(2025, 10, 27, 10, 30), 'done', 61],
    ]);
    const sync = listed[1];
    expect(await read(d.files, sync.audio)).toBe('WAV');
    expect(await lib.store.readUserNotes(sync.id)).toBe('• ask about pricing');
    expect(await lib.store.readTranscript(sync.id)).toEqual([{ start: 0, end: 2.5, text: 'Hello all' }]);
    expect(await lib.store.readAiNotes(sync.id)).toBe('');
    expect(await lib.store.readUserNotes(listed[0].id)).toBe('draft before crash');
    expect(d.files.paths().filter((p) => p.startsWith(SWIFT))).toEqual(before);
  });

  test('an imported meeting can be transcribed again and have notes written', async () => {
    const { retranscribe, regenerate } = await import('./pipeline');
    const d = disk();
    await swiftMeeting(d.files, '2025-11-27_1030_Sync', { 'recording.wav': 'WAV', 'transcript.json': '[]' });
    const lib = library(d.files, d.system, true);
    await desk(d.system, lib, async (p) => p).importAll(0);
    const [m] = await lib.store.list();
    expect(retranscribe(m).stage.kind).toBe('recorded');
    expect(regenerate({ ...m, stage: { kind: 'done' } }).stage.kind).toBe('summarizing');
  });

  test('a host with no folder access finds nothing to import', async () => {
    const d = disk();
    const lib = library(d.files, NO_SYSTEM, false);
    expect(await desk(NO_SYSTEM, lib, async (p) => p).view(0, true)).toMatchObject({ legacyCount: 0, foldersSupported: false, detectionSupported: false });
  });
});

describe('system audio', () => {
  const capturing = (mix: System['mix']) => {
    const d = disk();
    const system: System = {
      ...d.system,
      facts: async () => ({ ...(await d.system.facts()), capture: true }),
      startCapture: async () => true,
      stopCapture: async () => ({ path: 'app:/data/meetings/m1/system.m4a', offsetMs: 40, health: 'heard' }),
      mix,
    };
    return desk(system, library(d.files, system, true), async (p) => p);
  };

  test('a take with system audio keeps the mix', async () => {
    const calls: unknown[] = [];
    const tools = capturing(async (...args) => void calls.push(args));
    await tools.startCapture('m1', true);
    expect(await tools.finish('m1', 'app:/data/meetings/m1/audio.m4a')).toBe('app:/data/meetings/m1/audio-mixed.m4a');
    expect(calls).toEqual([['app:/data/meetings/m1/audio.m4a', 'app:/data/meetings/m1/system.m4a', 40, 'app:/data/meetings/m1/audio-mixed.m4a']]);
    expect((await tools.view(0, true)).captureHealth).toBe('heard');
  });

  test('a failed mix, or capture switched off, keeps the microphone recording', async () => {
    const failing = capturing(async () => Promise.reject(new Error('no')));
    await failing.startCapture('m1', true);
    expect(await failing.finish('m1', 'mic.m4a')).toBe('mic.m4a');
    const off = capturing(async () => {});
    await off.startCapture('m1', false);
    expect(await off.finish('m1', 'mic.m4a')).toBe('mic.m4a');
  });
});

describe('meeting detection', () => {
  const answering = (reply: Record<string, unknown>) => {
    const watched: string[] = [];
    const native = { available: true, later: async () => reply, watch: (topic: string) => void watched.push(topic) };
    return { system: nativeSystem(native), watched };
  };

  test('a call the module names is offered, keyed by app and title', async () => {
    const { system, watched } = answering({ app: 'zoom', title: 'Zoom meeting' });
    const tools = desk(system, library(memoryFiles(), system, true), async (p) => p);
    expect(await tools.detection(true)).toEqual({ found: true, app: 'zoom', title: 'Zoom meeting', key: 'zoom|Zoom meeting' });
    expect(watched).toEqual(['meeting']);
  });

  test('a browser with the microphone is offered without knowing the page', async () => {
    const { system } = answering({ app: 'browser', title: 'A call in Arc' });
    expect(await desk(system, library(memoryFiles(), system, true), async (p) => p).detection(true)).toMatchObject({ found: true, app: 'browser' });
  });

  test('nothing is offered for an unknown app, a failed module or detection turned off', async () => {
    for (const reply of [{ app: 'skype' }, {}]) {
      const { system } = answering(reply);
      expect((await desk(system, library(memoryFiles(), system, true), async (p) => p).detection(true)).found).toBe(false);
    }
    const { system, watched } = answering({ app: 'zoom' });
    expect((await desk(system, library(memoryFiles(), system, true), async (p) => p).detection(false)).found).toBe(false);
    expect(watched).toEqual([]);
  });
});
