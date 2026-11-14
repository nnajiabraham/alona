import type { Segment, TierId } from './types';

/** Token budgets per tier, from docs/research/local-models-2026-11.md, section 4. Starting values, not tuned. */
const BUDGETS: Record<TierId, { oneShot: number; chunk: number }> = {
  lite: { oneShot: 3000, chunk: 1500 },
  balanced: { oneShot: 8000, chunk: 3000 },
  quality: { oneShot: 24000, chunk: 6000 },
};

const TOKENS_PER_WORD = 1.3;

function estimateTokens(text: string): number {
  const words = text.split(/\s+/).filter((w) => w !== '').length;
  return Math.ceil(words * TOKENS_PER_WORD);
}

export function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s < 10 ? '0' : ''}${s}`;
}

const line = (s: Segment): string => `[${clock(s.start)}] ${s.text.trim()}`;

function transcriptText(segments: Segment[]): string {
  return segments.map(line).join('\n');
}

/**
 * Splits a transcript into chunks under the tier's map budget. A chunk ends
 * on a segment boundary and repeats the previous chunk's last segment, so a
 * statement cut at the boundary keeps its context.
 */
function chunk(segments: Segment[], budget: number): string[] {
  const chunks: string[] = [];
  let current: Segment[] = [];
  let used = 0;
  for (const segment of segments) {
    const cost = estimateTokens(line(segment));
    if (current.length > 1 && used + cost > budget) {
      chunks.push(current.map(line).join('\n'));
      const overlap = current[current.length - 1];
      current = [overlap];
      used = estimateTokens(line(overlap));
    }
    current.push(segment);
    used += cost;
  }
  if (current.length > 0) chunks.push(current.map(line).join('\n'));
  return chunks;
}

export type NotesPlan =
  | { kind: 'empty' }
  | { kind: 'oneShot'; transcript: string }
  | { kind: 'mapReduce'; chunks: string[] };

export function planNotes(segments: Segment[], userNotes: string, tier: TierId): NotesPlan {
  const spoken = segments.filter((s) => s.text.trim() !== '');
  if (spoken.length === 0) return { kind: 'empty' };
  const transcript = transcriptText(spoken);
  const budget = BUDGETS[tier];
  if (estimateTokens(transcript) + estimateTokens(userNotes) <= budget.oneShot) {
    return { kind: 'oneShot', transcript };
  }
  return { kind: 'mapReduce', chunks: chunk(spoken, budget.chunk) };
}

/** How many `generate` calls the plan needs: one, or one per chunk plus the merge. */
export function stepCount(plan: NotesPlan): number {
  switch (plan.kind) {
    case 'empty':
      return 0;
    case 'oneShot':
      return 1;
    case 'mapReduce':
      return plan.chunks.length + 1;
  }
}

export interface GenerateRequest {
  system: string;
  prompt: string;
  maxTokens: number;
}

/** One section of the notes: its heading, and what the model writes under it. */
export interface NoteSection {
  heading: string;
  guidance: string;
}

/**
 * What a notes model is asked to write, as data, so one pipeline serves
 * Alona's meeting notes and other apps' formats.
 */
export interface NotesProfile {
  /** What the recording is, as the prompts name it: "meeting", "consultation". */
  recording: string;
  system: string;
  extractSystem: string;
  /** The format's first line. */
  intro: string;
  /** The instruction for a title line, or `''` when the notes have none. */
  titleRule: string;
  sections: readonly NoteSection[];
  /** Instructions after the section list, or `''`. */
  closing: string;
  /** What goes under a section the model left out. */
  missingSection: string;
  /** What each part of a long recording is read for. */
  extractHeadings: readonly string[];
  /** The notes of a recording with no speech. */
  emptyResult: string;
  /** Introduces the person's own notes in the prompt. */
  ownNotesLabel: string;
}

export const ALONA_NOTES: NotesProfile = {
  recording: 'meeting',
  system: `You write meeting notes from a transcript. Use only what was said. Never invent names, dates, numbers, or decisions. If the person's own notes are given, treat them as what matters most to them and cover those topics first. Reply with the notes only, in the meeting's language.`,
  extractSystem: `You extract facts from one part of a meeting transcript. Use only what was said in this part. Never invent names, dates, numbers, or decisions. Reply with short bullets only.`,
  intro: 'Write the meeting notes in Markdown.',
  titleRule: 'Begin with one line that starts with "Title: " and then names what this meeting was about in three to six words.',
  sections: [
    { heading: 'Summary', guidance: 'two to four sentences.' },
    { heading: 'Key points', guidance: 'one bullet per point.' },
    { heading: 'Decisions', guidance: 'one bullet per decision that was made. If none was made, write "- None recorded."' },
    { heading: 'Action items', guidance: 'one line per task, written as "- [ ] Owner: task", with the due date if one was said. If there are none, write "- None recorded."' },
    { heading: 'Open questions', guidance: 'one bullet per question left unanswered. If there are none, write "- None recorded."' },
  ],
  closing: '',
  missingSection: '- None recorded.',
  extractHeadings: ['Topics', 'Decisions', 'Action items', 'Open questions'],
  emptyResult: '## Summary\nNo speech was detected in this recording.',
  ownNotesLabel: "The person's own notes from the meeting:",
};

const NUMBER_WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve'];
const count = (n: number): string => NUMBER_WORDS[n] ?? String(n);

function format(p: NotesProfile): string {
  const n = p.sections.length;
  const which = `${count(n)} section${n === 1 ? '' : 's'}`;
  const order = p.titleRule === ''
    ? `Write these ${which} in this order.`
    : `${p.titleRule}\n\nAfter the title, write these ${which} in this order.`;
  const list = p.sections.map((s) => `"## ${s.heading}": ${s.guidance}`).join('\n');
  const closing = p.closing === '' ? '' : `\n\n${p.closing}`;
  return `${p.intro}\n\n${order} Each section starts with its heading on its own line.\n\n${list}${closing}`;
}

const ownNotes = (p: NotesProfile, userNotes: string): string =>
  userNotes.trim() === '' ? '' : `\n\n${p.ownNotesLabel}\n${userNotes.trim()}`;

function oneShot(p: NotesProfile, transcript: string, userNotes: string): GenerateRequest {
  return {
    system: p.system,
    prompt: `${format(p)}\n\nTranscript:\n${transcript}${ownNotes(p, userNotes)}`,
    maxTokens: 900,
  };
}

function extract(p: NotesProfile, chunkText: string, index: number, total: number): GenerateRequest {
  const headings = p.extractHeadings.map((h) => `${h}:`).join('\n');
  return {
    system: p.extractSystem,
    prompt: `This is part ${index + 1} of ${total} of a ${p.recording} transcript. List what this part contains under these headings, one bullet each, keeping who said it and the time in brackets:

${headings}

Write "- none" under a heading with nothing to list.

Transcript part:
${chunkText}`,
    maxTokens: 400,
  };
}

function merge(p: NotesProfile, partials: string[], userNotes: string): GenerateRequest {
  const parts = partials.map((part, i) => `Part ${i + 1}:\n${part.trim()}`).join('\n\n');
  return {
    system: p.system,
    prompt: `${format(p)}\n\nThe ${p.recording} was long, so it was read in parts. These are the facts extracted from each part, in order. Merge them, remove repeats, and when two parts disagree keep the later one.\n\n${parts}${ownNotes(p, userNotes)}`,
    maxTokens: 900,
  };
}

/**
 * Qwen3.5's chat markup with its reasoning switched off (an empty think
 * block). Every tier's notes model is a Qwen3.5, so this is the one template.
 */
export const chatPrompt = (request: GenerateRequest): string =>
  `<|im_start|>system\n${request.system}<|im_end|>\n<|im_start|>user\n${request.prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n`;

/** The `generate` request for one step of the plan. `partials` are the outputs of the steps before it. */
export function stepRequest(profile: NotesProfile, plan: NotesPlan, step: number, partials: string[], userNotes: string): GenerateRequest {
  switch (plan.kind) {
    case 'empty':
      throw new Error('An empty transcript has no notes step.');
    case 'oneShot':
      return oneShot(profile, plan.transcript, userNotes);
    case 'mapReduce':
      return step < plan.chunks.length
        ? extract(profile, plan.chunks[step], step, plan.chunks.length)
        : merge(profile, partials, userNotes);
  }
}

export interface FinishedNotes {
  title: string;
  markdown: string;
}

/**
 * Turns the model's raw reply into the notes file. Small models wrap replies
 * in reasoning blocks and code fences, and sometimes skip the title line.
 */
export function finishNotes(profile: NotesProfile, raw: string): FinishedNotes {
  let text = raw.replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*$/, '');
  text = text.replace(/^\s*```(?:markdown|md)?\s*\n/, '').replace(/\n```\s*$/, '').trim();
  const labelled = /^\s*(?:#+\s*)?\**Title:?\**:?\s*(.+)$/im.exec(text);
  const heading = labelled ? null : /^\s*#\s+(.+)/.exec(text);
  const found = labelled ?? heading;
  const title = found ? cleanTitle(found[1]) : '';
  const markdown = (found ? text.replace(found[0], '') : text).trim();
  return { title, markdown: markdown === '' ? profile.emptyResult : withEverySection(profile, markdown) };
}

const escape = (text: string): string => text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/**
 * Models often leave out a section that has nothing in it. The notes always
 * show every section, so a missing one is added and says so.
 */
function withEverySection(profile: NotesProfile, markdown: string): string {
  const has = (name: string): boolean => new RegExp(`^#{1,3}\\s*${escape(name)}\\s*$`, 'im').test(markdown);
  const missing = profile.sections.filter((s) => !has(s.heading));
  return [markdown, ...missing.map((s) => `## ${s.heading}\n${profile.missingSection}`)].join('\n\n');
}

/** A title the model wrote, or `''` when it only repeated the instruction it was given. */
function cleanTitle(raw: string): string {
  const title = raw.replace(/[*#"]/g, '').trim().replace(/[.:]$/, '');
  const echoed = /short title|three to six words|names what this meeting/i.test(title);
  return echoed || title.length > 80 ? '' : title;
}
