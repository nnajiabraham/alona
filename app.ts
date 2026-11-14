import type { Answer, NativeModule, Sources, Storage } from './app.contract.d.ts';
import { engineOver, parseDeviceFacts, type DeviceFacts, type EngineRequest } from './core/engine';
import { service, type Service } from './core/service';
import { SIM_DEVICE, simEngine } from './core/sim-engine';
import { meetingStore, type Files } from './core/store';

const DIR = 'app:/data';
export const grants = `device.microphone purpose.microphone\nfs.read ${DIR}\nfs.write ${DIR}`;

let current: Promise<Service> | null = null;

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
 * A host's engine may answer its probe with `demo: true` to say it cannot run
 * models where it is, as the web engine does under browser automation. The
 * app then uses the demo engine and says so on screen.
 */
async function build(storage: Storage, native: NativeModule | null | undefined): Promise<Service> {
  const store = meetingStore(storage.fs);
  const demo = (device: DeviceFacts = SIM_DEVICE): Service =>
    service(simEngine({ polls: 3, shelf: demoShelf(storage.fs), device }), store, true);
  if (native?.available !== true) return demo();
  // Android reports a native module because the recording packages are native, but nothing there
  // answers the engine protocol yet, so its probe fails. It is the only such host.
  const probe = await native.later({ op: 'probe' }).catch(() => null);
  if (probe === null || typeof probe.host !== 'string') {
    return demo({ ...SIM_DEVICE, host: 'android', formFactor: 'phone' });
  }
  if (probe.demo === true) {
    // The demo keeps its sample memory and GPU, so captures match on every machine, but speaks as the real host.
    const real = parseDeviceFacts(probe);
    return demo({ ...SIM_DEVICE, host: real.host, formFactor: real.formFactor, appleSilicon: real.appleSilicon });
  }
  return service(engineOver((request: EngineRequest) => native.later({ ...request })), store, false);
}

/**
 * One service for the life of the module, so the pipeline's "a tick is
 * already running" guard and the demo engine's jobs survive between calls.
 */
const app = (storage: Storage, native: NativeModule | null | undefined): Promise<Service> =>
  (current ??= build(storage, native));

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
