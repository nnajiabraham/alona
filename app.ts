import type { Answer, NativeModule, Sources, Storage } from './app.contract.d.ts';
import { desk, type Desk } from './core/desk';
import { hostService } from './core/host';
import { library } from './core/library';
import type { Service } from './core/service';
import { nativeSystem, NO_SYSTEM } from './core/system';

const DIR = 'app:/data';
export const grants = [
  'device.microphone purpose.microphone',
  'device.notifications purpose.notifications',
  `fs.read ${DIR}`,
  `fs.write ${DIR}`,
  'fs.read doc:/',
].join('\n');

interface App {
  service: Service;
  desk: Desk;
}

let current: Promise<App> | null = null;

/**
 * One service for the life of the module, so the pipeline's "a tick is
 * already running" guard and the demo engine's jobs survive between calls.
 */
const app = (storage: Storage, native: NativeModule | null | undefined): Promise<App> =>
  (current ??= (async () => {
    const system = native?.available ? nativeSystem(native) : NO_SYSTEM;
    const lib = library(storage.fs, system, (await system.facts()).folders);
    const tools = desk(system, lib, (chosen) => storage.fs.realpath(chosen));
    const host = await hostService(storage.fs, native, { store: lib.store, onIdle: lib.settle, finishRecording: tools.finish });
    return { service: host.service, desk: tools };
  })());

const svc = async (storage: Storage, native: NativeModule | null | undefined): Promise<Service> => (await app(storage, native)).service;
const dsk = async (storage: Storage, native: NativeModule | null | undefined): Promise<Desk> => (await app(storage, native)).desk;

const sources: Sources = {
  loadSetup: async ([picked], _store, storage, native) => (await svc(storage, native)).setup(picked),
  downloadTier: async ([tier], _store, storage, native) => (await svc(storage, native)).downloadTier(tier),
  removeTierModels: async ([tier], _store, storage, native) => (await svc(storage, native)).removeTier(tier),
  tickPipeline: async ([picked], _store, storage, native) => (await svc(storage, native)).tick(picked),
  loadMeetings: async (_args, _store, storage, native) => (await svc(storage, native)).rows(),
  loadMeeting: async ([id], _store, storage, native) => (await svc(storage, native)).detail(id),
  createMeeting: async ([id, title, audio, durationMs, notes, createdAt, tier], _store, storage, native) => (await svc(storage, native)).create(id, title, audio, durationMs, notes, createdAt, tier),
  saveNotes: async ([id, text], _store, storage, native) => (await svc(storage, native)).saveNotes(id, text),
  renameMeeting: async ([id, title], _store, storage, native) => (await svc(storage, native)).rename(id, title),
  deleteMeeting: async ([id], _store, storage, native) => (await svc(storage, native)).remove(id),
  retryMeeting: async ([id], _store, storage, native) => (await svc(storage, native)).retry(id),
  regenerateNotes: async ([id], _store, storage, native) => (await svc(storage, native)).regenerate(id),
  retranscribeMeeting: async ([id], _store, storage, native) => (await svc(storage, native)).retranscribe(id),
  loadDesk: async ([utcOffset], _store, storage, native) => (await dsk(storage, native)).view(utcOffset),
  chooseMeetingsFolder: async ([chosen], _store, storage, native) => (await dsk(storage, native)).chooseFolder(chosen),
  pickLegacyFolder: async ([chosen], _store, storage, native) => (await dsk(storage, native)).pickLegacy(chosen),
  importLegacy: async ([utcOffset], _store, storage, native) => (await dsk(storage, native)).importAll(utcOffset),
  loadDetection: async ([enabled], _store, storage, native) => (await dsk(storage, native)).detection(enabled),
  startSystemAudio: async ([id, on], _store, storage, native) => (await dsk(storage, native)).startCapture(id, on),
};

export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
