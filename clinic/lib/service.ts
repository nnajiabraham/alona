import type { Service } from '../../core/service';
import type { MeetingStore } from '../../core/store';
import type { NotesProfile } from '../../core/notes';
import { isTierId } from '../../core/types';
import type { TenantConfig } from '../../tenants/schema';
import { templateOf, templateProfile } from './profile';

/**
 * A clinic note is an Alona meeting plus three files of the clinician's,
 * beside the pipeline's: `clinic.json` (patient reference and template),
 * `edited.md` (their edits of the draft) and `review.json` (when they
 * reviewed it, and the text they reviewed). The pipeline writes none of them.
 *
 * A note written again as another template is a second meeting of its own
 * (core's `fork`): it plays the first note's recording and starts from copies
 * of its transcript and jottings, so its draft, edits and review never touch
 * the first note's. Its `clinic.json` names the note it came from.
 */
const FILES = { record: 'clinic.json', edits: 'edited.md', review: 'review.json' } as const;

export type NoteState = 'processing' | 'failed' | 'draft' | 'reviewed';

interface ClinicRecord {
  patientRef: string;
  templateId: string;
  /** The template of the note this one was written again from, or '' for a note from a recording. */
  fromTemplateId: string;
}

interface Review {
  at: number;
  text: string;
}

export interface NoteRow {
  id: string;
  patientRef: string;
  templateName: string;
  createdAt: number;
  durationS: number;
  state: NoteState;
  stateLabel: string;
  progress: number;
}

export interface SegmentView {
  id: string;
  at: string;
  text: string;
}

export interface NoteDetail extends NoteRow {
  found: boolean;
  templateId: string;
  status: string;
  audio: string;
  error: string;
  /** The model's draft, as the pipeline wrote it. */
  draft: string;
  /** The note as shown: the clinician's edits when there are any, else the draft. */
  note: string;
  hasEdits: boolean;
  /** When the note as shown was reviewed; 0 when it was not, or changed since. */
  reviewedAt: number;
  jottings: string;
  segments: SegmentView[];
  /** The name of the template this note was written again from, or '' for a note from a recording. */
  writtenFrom: string;
  /** Another note plays the same recording, so deleting this one keeps it. */
  sharesRecording: boolean;
}

export interface Reply {
  ok: boolean;
  error: string;
}

export interface TemplateView {
  id: string;
  name: string;
  description: string;
  headings: string;
}

/** Everything the view shows of the tenant. */
export interface BrandView {
  name: string;
  tagline: string;
  version: string;
  welcomeTitle: string;
  welcomeBody: string;
  person: string;
  persons: string;
  Person: string;
  reviewDisclaimer: string;
  privacy: string;
  supportEmail: string;
  supportUrl: string;
  supportHours: string;
  jottings: boolean;
  copy: boolean;
  share: boolean;
  playback: boolean;
  defaultTemplate: string;
  defaultTier: string;
  templates: TemplateView[];
}

const MISSING: NoteDetail = {
  found: false, id: '', patientRef: '', templateName: '', templateId: '', createdAt: 0, durationS: 0, state: 'processing',
  stateLabel: '', progress: 0, status: '', audio: '', error: '', draft: '', note: '', hasEdits: false, reviewedAt: 0,
  jottings: '', segments: [], writtenFrom: '', sharesRecording: false,
};

const OK: Reply = { ok: true, error: '' };
const refused = (error: string): Reply => ({ ok: false, error });
const GONE = 'That note is gone.';
const isNoteId = (id: string): boolean => /^[A-Za-z0-9_-]+$/.test(id);

const capital = (s: string): string => s.charAt(0).toUpperCase() + s.slice(1);

function parse(text: string): Record<string, unknown> {
  if (text === '') return {};
  try {
    const raw: unknown = JSON.parse(text);
    return typeof raw === 'object' && raw !== null && !Array.isArray(raw) ? Object.fromEntries(Object.entries(raw)) : {};
  } catch {
    return {};
  }
}

const parseRecord = (text: string): ClinicRecord => {
  const r = parse(text);
  const str = (v: unknown): string => (typeof v === 'string' ? v : '');
  return { patientRef: str(r.patientRef), templateId: str(r.templateId), fromTemplateId: str(r.fromTemplateId) };
};

const parseReview = (text: string): Review | null => {
  const r = parse(text);
  return typeof r.at === 'number' && typeof r.text === 'string' ? { at: r.at, text: r.text } : null;
};

/** Where a note is, from the pipeline's stage and whether the note as shown is the one reviewed. */
export function noteState(status: string, note: string, review: Review | null): NoteState {
  if (status === 'failed') return 'failed';
  if (status !== 'done') return 'processing';
  return review !== null && review.text === note ? 'reviewed' : 'draft';
}

function stateLabel(state: NoteState, status: string): string {
  switch (state) {
    case 'processing':
      return status === 'transcribing' ? 'Transcribing' : status === 'summarizing' ? 'Writing draft' : 'Waiting to start';
    case 'failed':
      return 'Needs attention';
    case 'draft':
      return 'Draft';
    case 'reviewed':
      return 'Reviewed';
  }
}

export function brandView(tenant: TenantConfig): BrandView {
  return {
    name: tenant.app.name,
    tagline: tenant.app.tagline,
    version: tenant.app.version,
    welcomeTitle: tenant.copy.welcomeTitle,
    welcomeBody: tenant.copy.welcomeBody,
    person: tenant.copy.person.singular,
    persons: tenant.copy.person.plural,
    Person: capital(tenant.copy.person.singular),
    reviewDisclaimer: tenant.copy.reviewDisclaimer,
    privacy: tenant.copy.privacy,
    supportEmail: tenant.support?.email ?? '',
    supportUrl: tenant.support?.url ?? '',
    supportHours: tenant.support?.hours ?? '',
    ...tenant.features,
    defaultTemplate: tenant.defaults.template,
    defaultTier: tenant.defaults.tier,
    templates: tenant.templates.map((t) => ({
      id: t.id, name: t.name, description: t.description, headings: t.sections.map((s) => s.heading).join(' · '),
    })),
  };
}

/** The profile the pipeline writes one note's draft with: its template's. */
export const profileFor = (store: MeetingStore, tenant: TenantConfig) => async (m: { id: string }): Promise<NotesProfile> =>
  templateProfile(templateOf(tenant, parseRecord(await store.readExtra(m.id, FILES.record)).templateId), tenant);

/** The clinic app's operations, over Alona's service and the same store. */
export function clinicService(core: Service, store: MeetingStore, tenant: TenantConfig) {
  const person = tenant.copy.person.singular;
  const files = async (id: string) => {
    const [record, edits, review] = await Promise.all([
      store.readExtra(id, FILES.record), store.readExtra(id, FILES.edits), store.readExtra(id, FILES.review),
    ]);
    return { record: parseRecord(record), edits, review: parseReview(review) };
  };
  const exists = async (id: string): Promise<boolean> => isNoteId(id) && (await store.load(id)) !== null;
  const discardEdits = (id: string): Promise<void> => store.writeExtra(id, FILES.edits, '');

  async function noteOf(id: string, status: string, createdAt: number, durationS: number, progress: number) {
    const f = await files(id);
    const note = f.edits !== '' ? f.edits : await store.readAiNotes(id);
    const state = noteState(status, note, f.review);
    const template = templateOf(tenant, f.record.templateId);
    const row: NoteRow = {
      id,
      patientRef: f.record.patientRef !== '' ? f.record.patientRef : `No ${person} reference`,
      templateName: template.name,
      createdAt,
      durationS,
      state,
      stateLabel: stateLabel(state, status),
      progress,
    };
    return { row, record: f.record, templateId: template.id, note, edits: f.edits, review: f.review };
  }

  /** The person's pick of model tier, or the tenant's default before they pick. */
  const tier = (picked: string): string => (picked === '' ? tenant.defaults.tier : picked);

  return {
    setup: (picked: string) => core.setup(tier(picked)),
    tick: (picked: string) => core.tick(tier(picked)),
    downloadTier: (t: string): Promise<Reply> => core.downloadTier(t),
    removeTier: (t: string): Promise<Reply> => core.removeTier(t),

    async rows(): Promise<NoteRow[]> {
      const rows = await core.rows();
      return Promise.all(rows.map(async (r) => (await noteOf(r.id, r.status, r.createdAt, r.durationS, r.progress)).row));
    },

    async detail(id: string): Promise<NoteDetail> {
      const d = await core.detail(id);
      if (!d.found) return MISSING;
      const n = await noteOf(id, d.status, d.createdAt, d.durationS, d.progress);
      const own = await store.load(id);
      const sharesRecording = own !== null && (await store.list()).some((m) => m.id !== id && m.audio === own.audio);
      return {
        ...n.row,
        found: true,
        templateId: n.templateId,
        status: d.status,
        audio: d.audio,
        error: d.error,
        draft: d.aiNotes,
        note: n.note,
        hasEdits: n.edits !== '',
        reviewedAt: n.row.state === 'reviewed' && n.review ? n.review.at : 0,
        jottings: d.userNotes,
        segments: d.segments,
        writtenFrom: n.record.fromTemplateId !== '' ? templateOf(tenant, n.record.fromTemplateId).name : '',
        sharesRecording,
      };
    },

    async create(id: string, patientRef: string, templateId: string, audio: string, durationMs: number, jottings: string, createdAt: number, tier: string): Promise<Reply> {
      if (!isNoteId(id) || audio === '') return refused('The recording was not saved.');
      const template = templateOf(tenant, templateId);
      // The record is written first, so the pipeline never starts this note with another template.
      await store.writeExtra(id, FILES.record, JSON.stringify({ patientRef: patientRef.trim(), templateId: template.id, fromTemplateId: '' } satisfies ClinicRecord));
      return core.create(id, '', audio, durationMs, jottings, createdAt, isTierId(tier) ? tier : 'lite');
    },

    async setPatientRef(id: string, patientRef: string): Promise<Reply> {
      if (!(await exists(id))) return refused(GONE);
      const f = await files(id);
      await store.writeExtra(id, FILES.record, JSON.stringify({ ...f.record, patientRef: patientRef.trim() } satisfies ClinicRecord));
      return OK;
    },

    async saveEdits(id: string, text: string): Promise<Reply> {
      if (!(await exists(id))) return refused(GONE);
      const m = await store.load(id);
      if (m?.stage.kind !== 'done') return refused('The draft is still being written.');
      // An edit that puts the draft back exactly as written is no edit, so Write again need not ask.
      await store.writeExtra(id, FILES.edits, text === (await store.readAiNotes(id)) ? '' : text);
      return OK;
    },

    saveJottings: (id: string, text: string): Promise<Reply> => core.saveNotes(id, text),

    async markReviewed(id: string, at: number): Promise<Reply> {
      if (!(await exists(id))) return refused(GONE);
      const m = await store.load(id);
      if (m?.stage.kind !== 'done') return refused('There is no draft to review yet.');
      const f = await files(id);
      const note = f.edits !== '' ? f.edits : await store.readAiNotes(id);
      await store.writeExtra(id, FILES.review, JSON.stringify({ at, text: note } satisfies Review));
      return OK;
    },

    async writeAgain(id: string): Promise<Reply> {
      if (!(await exists(id))) return refused(GONE);
      await discardEdits(id);
      return core.regenerate(id);
    },

    /**
     * A new note `id` beside note `from`, in another template, drafted from the same transcript
     * and jottings for the same patient reference. It starts as an unreviewed draft; `from` and
     * its review are untouched.
     */
    async writeAs(from: string, templateId: string, id: string): Promise<Reply> {
      if (!(await exists(from))) return refused(GONE);
      const template = tenant.templates.find((t) => t.id === templateId);
      if (!template) return refused('That template is not offered here.');
      if (!isNoteId(id) || (await store.load(id)) !== null) return refused('That note already exists.');
      if ((await store.load(from))?.stage.kind !== 'done') return refused('The draft is still being written.');
      const source = (await files(from)).record;
      // The record is written before the meeting exists, so the pipeline never drafts this note with another template.
      await store.mkdirMeeting(id);
      await store.writeExtra(id, FILES.record, JSON.stringify({
        patientRef: source.patientRef, templateId: template.id, fromTemplateId: templateOf(tenant, source.templateId).id,
      } satisfies ClinicRecord));
      const reply = await core.fork(from, id);
      if (!reply.ok) await store.remove(id);
      return reply;
    },

    async transcribeAgain(id: string): Promise<Reply> {
      if (!(await exists(id))) return refused(GONE);
      await discardEdits(id);
      return core.retranscribe(id);
    },

    retry: (id: string): Promise<Reply> => core.retry(id),
    remove: (id: string): Promise<Reply> => core.remove(id),
  };
}

export type ClinicService = ReturnType<typeof clinicService>;
