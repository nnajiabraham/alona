import type { Segment, TierId } from '../types';

const line = (i: number): Segment => ({
  start: i * 6,
  end: i * 6 + 6,
  text: `Speaker ${i % 3} said point number ${i} about the release, the budget and the schedule for next week.`,
});

export const shortSegments: Segment[] = Array.from({ length: 5 }, (_, i) => line(i));
export const longSegments: Segment[] = Array.from({ length: 150 }, (_, i) => line(i));

export const planCases: { name: string; segments: Segment[]; userNotes: string; tier: TierId }[] = [
  { name: 'short, no notes', segments: shortSegments, userNotes: '', tier: 'lite' },
  { name: 'short, with notes', segments: shortSegments, userNotes: '  - Ask about the login fix\n', tier: 'balanced' },
  { name: 'long on lite', segments: longSegments, userNotes: '- Budget', tier: 'lite' },
  { name: 'long on balanced', segments: longSegments, userNotes: '', tier: 'balanced' },
  { name: 'silence', segments: [{ start: 0, end: 3, text: '  ' }], userNotes: '', tier: 'lite' },
];

export const rawReplies: string[] = [
  'Title: Launch sync\n\n## Summary\nWe met.\n\n## Key points\n- One',
  '<think>hmm</think>```markdown\n# Weekly planning\n## Summary\nText\n## Decisions\n- Ship\n```',
  '**Title:** Short title in three to six words\n## Summary\nx',
  '<think>never closed',
  '## Summary\nNo title here.\n## Key points\n- a\n## Decisions\n- b\n## Action items\n- c\n## Open questions\n- d',
  '',
];
