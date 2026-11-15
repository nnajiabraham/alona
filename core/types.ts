export type TierId = 'lite' | 'balanced' | 'quality';

export const TIERS: readonly TierId[] = ['lite', 'balanced', 'quality'];

export type Host = 'web' | 'macos' | 'ios' | 'android';

export interface Segment {
  start: number;
  end: number;
  text: string;
}

export type FailedDuring = 'transcribing' | 'summarizing';

/**
 * Where a meeting is in the record, transcribe, summarize pipeline. A job id
 * of `''` means the stage's job has not been started yet. `steps` is how many
 * notes requests the plan had when the current one started.
 */
export type Stage =
  | { kind: 'recorded' }
  | { kind: 'transcribing'; job: string }
  | { kind: 'summarizing'; job: string; step: number; steps: number; partials: string[] }
  | { kind: 'done' }
  | { kind: 'failed'; during: FailedDuring; error: string };

export interface Meeting {
  id: string;
  title: string;
  createdAt: number;
  durationS: number;
  audio: string;
  tier: TierId;
  stage: Stage;
  /** Bumped by each retry so a retried stage never reuses a failed job's id. */
  attempt: number;
  /** The title the notes model proposed. Shown while `title` is empty. */
  suggestedTitle: string;
}

export const displayTitle = (m: Pick<Meeting, 'title' | 'suggestedTitle'>): string =>
  m.title !== '' ? m.title : m.suggestedTitle !== '' ? m.suggestedTitle : 'Untitled meeting';

export const isTierId = (value: unknown): value is TierId => TIERS.some((tier) => tier === value);
