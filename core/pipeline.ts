import type { Artifact, Engine, JobView } from './engine';
import { chatPrompt, finishNotes, NO_SPEECH_NOTES, planNotes, stepCount, stepRequest } from './notes';
import type { FailedDuring, Meeting, Segment, Stage } from './types';

/** Everything the pipeline touches outside the meeting record itself. */
export interface PipelineIO {
  engine: Engine;
  stt: Artifact;
  llm: Artifact;
  readUserNotes(meeting: Meeting): Promise<string>;
  readTranscript(meeting: Meeting): Promise<Segment[]>;
  writeTranscript(meeting: Meeting, segments: Segment[]): Promise<void>;
  writeAiNotes(meeting: Meeting, markdown: string): Promise<void>;
}

export interface Advance {
  meeting: Meeting;
  /** 0 to 1 across the whole pipeline, for the progress bar. */
  progress: number;
}

const TRANSCRIBE_SHARE = 0.5;

const sttJob = (m: Meeting): string => `${m.id}.a${m.attempt}.stt`;
const notesJob = (m: Meeting, step: number): string => `${m.id}.a${m.attempt}.notes${step}`;

const NOTES_NOT_STARTED: Stage = { kind: 'summarizing', job: '', step: 0, steps: 0, partials: [] };

const failed = (m: Meeting, during: FailedDuring, error: string): Advance => ({
  meeting: { ...m, stage: { kind: 'failed', during, error: error === '' ? 'The engine stopped without saying why.' : error } },
  progress: 0,
});

const at = (m: Meeting, stage: Stage, progress: number): Advance => ({ meeting: { ...m, stage }, progress });

async function startNotesStep(m: Meeting, io: PipelineIO, step: number, partials: string[]): Promise<Advance> {
  const segments = await io.readTranscript(m);
  const userNotes = await io.readUserNotes(m);
  const plan = planNotes(segments, userNotes, m.tier);
  const steps = stepCount(plan);
  if (steps === 0) {
    await io.writeAiNotes(m, NO_SPEECH_NOTES);
    return at(m, { kind: 'done' }, 1);
  }
  const request = stepRequest(plan, step, partials, userNotes);
  const job = notesJob(m, step);
  await io.engine.generate(job, io.llm, chatPrompt(request), request.maxTokens);
  return at(m, { kind: 'summarizing', job, step, steps, partials }, TRANSCRIBE_SHARE + ((1 - TRANSCRIBE_SHARE) * step) / steps);
}

async function summarizing(m: Meeting, io: PipelineIO, stage: Extract<Stage, { kind: 'summarizing' }>): Promise<Advance> {
  if (stage.job === '') return startNotesStep(m, io, stage.step, stage.partials);
  const plan = planNotes(await io.readTranscript(m), await io.readUserNotes(m), m.tier);
  const steps = stepCount(plan);
  // The plan depends on the person's notes and the tier, and both can change while a long summary
  // runs. Parts extracted under one plan do not fit another, so the summary starts over.
  if (steps !== stage.steps) return startNotesStep({ ...m, attempt: m.attempt + 1 }, io, 0, []);
  const view = await io.engine.job(stage.job);
  switch (view.state) {
    case 'unknown':
      return startNotesStep(m, io, stage.step, stage.partials);
    case 'failed':
      return failed(m, 'summarizing', view.error);
    case 'running':
      return at(m, stage, TRANSCRIBE_SHARE + ((1 - TRANSCRIBE_SHARE) * (stage.step + view.progress)) / steps);
    case 'done': {
      if (stage.step + 1 < steps) return startNotesStep(m, io, stage.step + 1, [...stage.partials, view.text]);
      const notes = finishNotes(view.text);
      await io.writeAiNotes(m, notes.markdown);
      return at({ ...m, suggestedTitle: notes.title }, { kind: 'done' }, 1);
    }
  }
}

async function transcribing(m: Meeting, io: PipelineIO, job: string): Promise<Advance> {
  const view: JobView = await io.engine.job(job);
  switch (view.state) {
    case 'unknown':
      await io.engine.transcribe(job, m.audio, io.stt);
      return at(m, { kind: 'transcribing', job }, 0);
    case 'failed':
      return failed(m, 'transcribing', view.error);
    case 'running':
      return at(m, { kind: 'transcribing', job }, TRANSCRIBE_SHARE * view.progress);
    case 'done':
      await io.writeTranscript(m, view.segments);
      return startNotesStep(m, io, 0, []);
  }
}

/**
 * Moves a meeting one step toward `done`. Safe to call at any time and after
 * a restart: each call reads where the meeting is, asks the engine about that
 * stage's job, and restarts the job when the engine no longer knows it.
 */
export async function advance(m: Meeting, io: PipelineIO): Promise<Advance> {
  const stage = m.stage;
  switch (stage.kind) {
    case 'recorded': {
      const job = sttJob(m);
      await io.engine.transcribe(job, m.audio, io.stt);
      return at(m, { kind: 'transcribing', job }, 0);
    }
    case 'transcribing':
      return transcribing(m, io, stage.job);
    case 'summarizing':
      return summarizing(m, io, stage);
    case 'done':
      return { meeting: m, progress: 1 };
    case 'failed':
      return { meeting: m, progress: 0 };
  }
}

/** Puts a failed meeting back at the start of the stage that failed. */
export function retry(m: Meeting): Meeting {
  if (m.stage.kind !== 'failed') return m;
  const stage: Stage =
    m.stage.during === 'transcribing' ? { kind: 'recorded' } : NOTES_NOT_STARTED;
  return { ...m, attempt: m.attempt + 1, stage };
}

/** Regenerates the AI notes of a finished meeting, for example after the person edits their notes or switches tier. */
export function regenerate(m: Meeting): Meeting {
  if (m.stage.kind !== 'done') return m;
  return { ...m, attempt: m.attempt + 1, stage: NOTES_NOT_STARTED };
}

/** Runs the whole pipeline again on a finished or failed meeting, for example after switching tier. */
export function retranscribe(m: Meeting): Meeting {
  if (m.stage.kind !== 'done' && m.stage.kind !== 'failed') return m;
  return { ...m, attempt: m.attempt + 1, stage: { kind: 'recorded' } };
}

export const isWorking = (m: Meeting): boolean =>
  m.stage.kind === 'recorded' || m.stage.kind === 'transcribing' || m.stage.kind === 'summarizing';
