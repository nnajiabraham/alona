import { engineOver, parseDeviceFacts, type DeviceFacts, type EngineRequest } from './engine';
import { service, type Service, type ServiceOptions } from './service';
import { SIM_DEVICE, simEngine, type SimOptions } from './sim-engine';
import { meetingStore, type Files, type MeetingStore } from './store';

/** The part of Exact's native module the engine choice reads. */
export interface Native {
  readonly available: boolean;
  later(request: Record<string, unknown>): Promise<Record<string, unknown>>;
}

export interface HostOptions extends ServiceOptions {
  /** The demo engine's transcript and notes, for an app whose samples differ from Alona's. */
  demo?: Pick<SimOptions, 'segments' | 'notes'>;
  /** Ends the note shown wherever samples appear. */
  sampleLine?: string;
}

const DEMO_SHELF = 'app:/data/demo-models.json';

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
 * Picks the host's engine, as Alona's app.ts does: the native module when it
 * answers a probe with a host, else the demo engine with the reason on screen.
 */
export async function hostService(files: Files, native: Native | null | undefined, options: HostOptions = {}): Promise<{ service: Service; store: MeetingStore }> {
  const store = meetingStore(files);
  const sample = options.sampleLine ?? 'Transcripts and notes shown here are samples.';
  const demo = (why: string, device: DeviceFacts = SIM_DEVICE): Service =>
    service(simEngine({ polls: 3, shelf: demoShelf(files), device, ...options.demo }), store, `${why} ${sample}`, options);
  if (native?.available !== true) return { service: demo('This build has no on-device models.'), store };
  // Android's native module serves recording only, so a probe there fails. It is the only host
  // that reports a native module and has no engine.
  const probe = await native.later({ op: 'probe' }).catch(() => null);
  if (probe === null || typeof probe.host !== 'string') {
    return { service: demo('The Android app has no on-device models.', { ...SIM_DEVICE, host: 'android', formFactor: 'phone' }), store };
  }
  if (probe.demo === true) {
    const real = parseDeviceFacts(probe);
    const why = typeof probe.demoReason === 'string' && probe.demoReason !== '' ? probe.demoReason : 'Models cannot run here.';
    return { service: demo(why, { ...SIM_DEVICE, host: real.host, formFactor: real.formFactor, appleSilicon: real.appleSilicon }), store };
  }
  return { service: service(engineOver((request: EngineRequest) => native.later({ ...request })), store, '', options), store };
}
