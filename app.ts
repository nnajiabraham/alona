import type { Answer, NativeModule, Sources, Storage } from './app.contract.d.ts';
import { hostService } from './core/host';
import type { Service } from './core/service';

const DIR = 'app:/data';
export const grants = `device.microphone purpose.microphone\nfs.read ${DIR}\nfs.write ${DIR}`;

let current: Promise<Service> | null = null;

/**
 * One service for the life of the module, so the pipeline's "a tick is
 * already running" guard and the demo engine's jobs survive between calls.
 */
const app = (storage: Storage, native: NativeModule | null | undefined): Promise<Service> =>
  (current ??= hostService(storage.fs, native).then((host) => host.service));

const sources: Sources = {
  loadSetup: async ([picked], _store, storage, native) => (await app(storage, native)).setup(picked),
  downloadTier: async ([tier], _store, storage, native) => (await app(storage, native)).downloadTier(tier),
  removeTierModels: async ([tier], _store, storage, native) => (await app(storage, native)).removeTier(tier),
  tickPipeline: async ([picked], _store, storage, native) => (await app(storage, native)).tick(picked),
  loadMeetings: async (_args, _store, storage, native) => (await app(storage, native)).rows(),
  loadMeeting: async ([id], _store, storage, native) => (await app(storage, native)).detail(id),
  createMeeting: async ([id, title, audio, durationMs, notes, createdAt, tier], _store, storage, native) => (await app(storage, native)).create(id, title, audio, durationMs, notes, createdAt, tier),
  saveNotes: async ([id, text], _store, storage, native) => (await app(storage, native)).saveNotes(id, text),
  renameMeeting: async ([id, title], _store, storage, native) => (await app(storage, native)).rename(id, title),
  deleteMeeting: async ([id], _store, storage, native) => (await app(storage, native)).remove(id),
  retryMeeting: async ([id], _store, storage, native) => (await app(storage, native)).retry(id),
  regenerateNotes: async ([id], _store, storage, native) => (await app(storage, native)).regenerate(id),
  retranscribeMeeting: async ([id], _store, storage, native) => (await app(storage, native)).retranscribe(id),
};

export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
