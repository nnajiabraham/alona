import type { Answer, NativeModule, Sources, Storage } from './app.contract.d.ts';
import { engineOver, type EngineRequest } from './core/engine';
import { service, type Service } from './core/service';
import { simEngine } from './core/sim-engine';
import { meetingStore, type Files } from './core/store';

const DIR = 'app:/data';
export const grants = `device.microphone purpose.microphone\nfs.read ${DIR}\nfs.write ${DIR}`;

let current: Service | null = null;

const DEMO_SHELF = `${DIR}/demo-models.json`;

const demoShelf = (files: Files) => ({
  load: async (): Promise<string[]> => {
    try {
      const ids: unknown = JSON.parse(new TextDecoder().decode(await files.readFile(DEMO_SHELF)));
      return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : [];
    } catch {
      return [];
    }
  },
  save: (ids: string[]): Promise<void> => files.atomicWriteFile(DEMO_SHELF, new TextEncoder().encode(JSON.stringify(ids))),
});

/**
 * One service for the life of the module, so the pipeline's "a tick is
 * already running" guard and the demo engine's jobs survive between calls.
 * A host without an inference module gets the demo engine.
 */
function app(storage: Storage, native: NativeModule | null | undefined): Service {
  if (current) return current;
  const real = native?.available === true;
  const engine = real
    ? engineOver((request: EngineRequest) => native.later({ ...request }))
    : simEngine({ polls: 3, shelf: demoShelf(storage.fs) });
  current = service(engine, meetingStore(storage.fs), !real);
  return current;
}

const sources: Sources = {
  loadSetup: ([picked], _store, storage, native) => app(storage, native).setup(picked),
  downloadTier: ([tier], _store, storage, native) => app(storage, native).downloadTier(tier),
  removeTierModels: ([tier], _store, storage, native) => app(storage, native).removeTier(tier),
  tickPipeline: ([picked], _store, storage, native) => app(storage, native).tick(picked),
  loadMeetings: (_args, _store, storage, native) => app(storage, native).rows(),
  loadMeeting: ([id], _store, storage, native) => app(storage, native).detail(id),
  createMeeting: ([id, title, audio, durationMs, notes, createdAt, tier], _store, storage, native) =>
    app(storage, native).create(id, title, audio, durationMs, notes, createdAt, tier),
  saveNotes: ([id, text], _store, storage, native) => app(storage, native).saveNotes(id, text),
  renameMeeting: ([id, title], _store, storage, native) => app(storage, native).rename(id, title),
  deleteMeeting: ([id], _store, storage, native) => app(storage, native).remove(id),
  retryMeeting: ([id], _store, storage, native) => app(storage, native).retry(id),
  regenerateNotes: ([id], _store, storage, native) => app(storage, native).regenerate(id),
};

export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
