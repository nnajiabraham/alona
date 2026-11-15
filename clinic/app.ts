import type { Answer, NativeModule, Sources, Storage } from './app.contract.d.ts';
import { hostService } from './core/host';
import { demoDraft, DEMO_CONSULTATION } from './clinic/lib/demo';
import { brandView, clinicService, profileFor, type ClinicService } from './clinic/lib/service';
import { TENANT } from './tenant';
import { meetingStore } from './core/store';
import { applyFormat, formatsAt } from './core/markdown';

const DIR = 'app:/data';
export const grants = `device.microphone purpose.microphone\nfs.read ${DIR}\nfs.write ${DIR}`;

let current: Promise<ClinicService> | null = null;

async function build(storage: Storage, native: NativeModule | null | undefined): Promise<ClinicService> {
  const profileOf = profileFor(meetingStore(storage.fs), TENANT);
  const { service, store } = await hostService(storage.fs, native, {
    profileOf,
    demo: { segments: DEMO_CONSULTATION, notes: demoDraft },
    sampleLine: 'The transcript and draft shown here are samples.',
  });
  return clinicService(service, store, TENANT);
}

/** One service for the life of the module, so the pipeline's tick guard and the demo engine's jobs survive between calls. */
const app = (storage: Storage, native: NativeModule | null | undefined): Promise<ClinicService> =>
  (current ??= build(storage, native));

const sources: Sources = {
  formatMarkdown: async ([source, start, end, command, argument]) => applyFormat(source, start, end, command, argument),
  markdownFormats: async ([source, start, end]) => formatsAt(source, start, end),
  loadBrand: async () => brandView(TENANT),
  loadSetup: async ([picked], _store, storage, native) => (await app(storage, native)).setup(picked),
  downloadTier: async ([tier], _store, storage, native) => (await app(storage, native)).downloadTier(tier),
  removeTierModels: async ([tier], _store, storage, native) => (await app(storage, native)).removeTier(tier),
  tickPipeline: async ([picked], _store, storage, native) => (await app(storage, native)).tick(picked),
  loadNotes: async (_args, _store, storage, native) => (await app(storage, native)).rows(),
  loadNote: async ([id], _store, storage, native) => (await app(storage, native)).detail(id),
  createNote: async ([id, patientRef, templateId, audio, durationMs, jottings, createdAt, tier], _store, storage, native) =>
    (await app(storage, native)).create(id, patientRef, templateId, audio, durationMs, jottings, createdAt, tier),
  setPatientRef: async ([id, ref], _store, storage, native) => (await app(storage, native)).setPatientRef(id, ref),
  saveEdits: async ([id, text], _store, storage, native) => (await app(storage, native)).saveEdits(id, text),
  saveJottings: async ([id, text], _store, storage, native) => (await app(storage, native)).saveJottings(id, text),
  markReviewed: async ([id, at], _store, storage, native) => (await app(storage, native)).markReviewed(id, at),
  writeAgain: async ([id], _store, storage, native) => (await app(storage, native)).writeAgain(id),
  writeAs: async ([from, templateId, id], _store, storage, native) => (await app(storage, native)).writeAs(from, templateId, id),
  transcribeAgain: async ([id], _store, storage, native) => (await app(storage, native)).transcribeAgain(id),
  retryNote: async ([id], _store, storage, native) => (await app(storage, native)).retry(id),
  deleteNote: async ([id], _store, storage, native) => (await app(storage, native)).remove(id),
};

export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
