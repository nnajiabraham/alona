import type { Segment } from '../core/types';

/** A synthetic consultation the demo engine returns as every transcript. No real person. */
export const DEMO_CONSULTATION: Segment[] = [
  { start: 0, end: 6, text: 'Hello, what brings you in today?' },
  { start: 6, end: 14, text: 'My left knee has been sore for about two weeks, since a long run. Stairs make it worse.' },
  { start: 14, end: 20, text: 'Any swelling or locking? Have you taken anything for it?' },
  { start: 20, end: 27, text: 'A little swelling in the evenings. No locking. I have not taken anything.' },
  { start: 27, end: 35, text: 'On examination there is mild swelling over the left knee and a full range of movement.' },
  { start: 35, end: 44, text: 'This looks like a minor strain. Rest from running, ice in the evening, and we will review in two weeks.' },
];

// First match wins, so the narrower headings come before the broader ones.
const SAMPLES: [RegExp, string][] = [
  [/reason|presenting|concern|complaint/i, '- Left knee pain for about two weeks.'],
  [/subjective|history/i, '- Left knee sore for about two weeks, since a long run.\n- Worse on stairs. Some evening swelling, no locking.\n- No medication taken.'],
  [/objective|exam|finding/i, '- Mild swelling over the left knee.\n- Full range of movement.'],
  [/assessment|impression/i, '- Minor strain, as the clinician said.'],
  [/follow|review/i, '- Review in two weeks.'],
  [/plan|next/i, '- Rest from running and ice in the evening.\n- Review in two weeks.'],
];

/**
 * The demo engine's draft: the requested sections, in order, filled from the
 * sample consultation. It reads the headings from the prompt, so it follows
 * whichever template the note uses.
 */
export function demoDraft(prompt: string): string {
  const headings = [...prompt.matchAll(/^"## (.+)": /gm)].map((m) => m[1]);
  const sections = headings.map((h) => `## ${h}\n${SAMPLES.find(([re]) => re.test(h))?.[1] ?? 'Not discussed.'}`);
  return ['> This is a sample draft from the demo engine. No model ran, and it does not describe your recording.', ...sections].join('\n\n');
}
