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

const FORMAT = `Write the meeting notes in Markdown.

Begin with one line that starts with "Title: " and then names what this meeting was about in three to six words.

After the title, write these five sections in this order. Each section starts with its heading on its own line.

"## Summary": two to four sentences.
"## Key points": one bullet per point.
"## Decisions": one bullet per decision that was made. If none was made, write "- None recorded."
"## Action items": one line per task, written as "- [ ] Owner: task", with the due date if one was said. If there are none, write "- None recorded."
"## Open questions": one bullet per question left unanswered. If there are none, write "- None recorded."`;

const SYSTEM = `You write meeting notes from a transcript. Use only what was said. Never invent names, dates, numbers, or decisions. If the person's own notes are given, treat them as what matters most to them and cover those topics first. Reply with the notes only, in the meeting's language.`;

const EXTRACT_SYSTEM = `You extract facts from one part of a meeting transcript. Use only what was said in this part. Never invent names, dates, numbers, or decisions. Reply with short bullets only.`;

const ownNotes = (userNotes: string): string =>
  userNotes.trim() === '' ? '' : `\n\nThe person's own notes from the meeting:\n${userNotes.trim()}`;

function oneShot(transcript: string, userNotes: string): GenerateRequest {
  return {
    system: SYSTEM,
    prompt: `${FORMAT}\n\nTranscript:\n${transcript}${ownNotes(userNotes)}`,
    maxTokens: 900,
  };
}

function extract(chunkText: string, index: number, total: number): GenerateRequest {
  return {
    system: EXTRACT_SYSTEM,
    prompt: `This is part ${index + 1} of ${total} of a meeting transcript. List what this part contains under these headings, one bullet each, keeping who said it and the time in brackets:

Topics:
Decisions:
Action items:
Open questions:

Write "- none" under a heading with nothing to list.

Transcript part:
${chunkText}`,
    maxTokens: 400,
  };
}

function merge(partials: string[], userNotes: string): GenerateRequest {
  const parts = partials.map((p, i) => `Part ${i + 1}:\n${p.trim()}`).join('\n\n');
  return {
    system: SYSTEM,
    prompt: `${FORMAT}\n\nThe meeting was long, so it was read in parts. These are the facts extracted from each part, in order. Merge them, remove repeats, and when two parts disagree keep the later one.\n\n${parts}${ownNotes(userNotes)}`,
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
export function stepRequest(plan: NotesPlan, step: number, partials: string[], userNotes: string): GenerateRequest {
  switch (plan.kind) {
    case 'empty':
      throw new Error('An empty transcript has no notes step.');
    case 'oneShot':
      return oneShot(plan.transcript, userNotes);
    case 'mapReduce':
      return step < plan.chunks.length
        ? extract(plan.chunks[step], step, plan.chunks.length)
        : merge(partials, userNotes);
  }
}

export interface FinishedNotes {
  title: string;
  markdown: string;
}

export const NO_SPEECH_NOTES = '## Summary\nNo speech was detected in this recording.';

/**
 * Turns the model's raw reply into the notes file. Small models wrap replies
 * in reasoning blocks and code fences, and sometimes skip the title line.
 */
export function finishNotes(raw: string): FinishedNotes {
  let text = raw.replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*$/, '');
  text = text.replace(/^\s*```(?:markdown|md)?\s*\n/, '').replace(/\n```\s*$/, '').trim();
  const labelled = /^\s*(?:#+\s*)?\**Title:?\**:?\s*(.+)$/im.exec(text);
  const heading = labelled ? null : /^\s*#\s+(.+)/.exec(text);
  const found = labelled ?? heading;
  const title = found ? cleanTitle(found[1]) : '';
  const markdown = (found ? text.replace(found[0], '') : text).trim();
  return { title, markdown: markdown === '' ? NO_SPEECH_NOTES : withEverySection(markdown) };
}

const SECTIONS = ['Summary', 'Key points', 'Decisions', 'Action items', 'Open questions'] as const;

/**
 * Models often leave out a section that has nothing in it. The notes always
 * show all five, so a missing one is added and says so.
 */
function withEverySection(markdown: string): string {
  const has = (name: string): boolean => new RegExp(`^#{1,3}\\s*${name}\\s*$`, 'im').test(markdown);
  const missing = SECTIONS.filter((name) => !has(name));
  return [markdown, ...missing.map((name) => `## ${name}\n- None recorded.`)].join('\n\n');
}

/** A title the model wrote, or `''` when it only repeated the instruction it was given. */
function cleanTitle(raw: string): string {
  const title = raw.replace(/[*#"]/g, '').trim().replace(/[.:]$/, '');
  const echoed = /short title|three to six words|names what this meeting/i.test(title);
  return echoed || title.length > 80 ? '' : title;
}
