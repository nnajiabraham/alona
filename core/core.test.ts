import { describe, expect, test } from 'bun:test';
import { assess, effectiveTier } from './device';
import type { Artifact, DeviceFacts } from './engine';
import { parseJobView } from './engine';
import { finishNotes, planNotes, stepCount, stepRequest } from './notes';
import { advance, isWorking, retry, type PipelineIO } from './pipeline';
import { SIM_DEVICE, SIM_SEGMENTS, simEngine, type SimOptions } from './sim-engine';
import type { Meeting, Segment } from './types';

const ALL = ['lite', 'balanced', 'quality'] as const;
const device = (over: Partial<DeviceFacts>): DeviceFacts => ({ ...SIM_DEVICE, ...over });

describe('tier selection', () => {
  test('a 96 GB Apple silicon Mac is recommended Quality and can run every tier', () => {
    const a = assess('macos', device({ memoryGB: 96, appleSilicon: true }), ALL);
    expect(a.recommended).toBe('quality');
    expect(a.verdicts.every((v) => v.runnable)).toBe(true);
  });

  test('a 4 GB phone gets Lite, and larger tiers say why they cannot run', () => {
    const a = assess('android', device({ memoryGB: 4, formFactor: 'phone' }), ALL);
    expect(a.recommended).toBe('lite');
    expect(a.verdicts.find((v) => v.tier === 'balanced')).toEqual({
      tier: 'balanced',
      runnable: false,
      reason: 'This device has 4 GB of memory.',
    });
  });

  test('a 12 GB phone stops at Balanced', () => {
    const a = assess('ios', device({ memoryGB: 12, formFactor: 'phone', appleSilicon: true }), ALL);
    expect(a.recommended).toBe('balanced');
    expect(a.verdicts.find((v) => v.tier === 'quality')?.runnable).toBe(false);
  });

  test('a browser without WebGPU gets Lite', () => {
    expect(assess('web', device({ gpu: false }), ALL).recommended).toBe('lite');
  });

  test('a browser on iPhone gets Lite even with WebGPU', () => {
    expect(assess('web', device({ iosBrowser: true, gpu: true }), ALL).recommended).toBe('lite');
  });

  test('a desktop browser with WebGPU, memory and storage gets Balanced, never Quality', () => {
    const a = assess('web', device({ memoryGB: 8, gpu: true, gpuMaxBufferGB: 2, storageFreeGB: 20 }), ALL);
    expect(a.recommended).toBe('balanced');
  });

  test('a browser that hides its memory is treated as unknown, not low', () => {
    expect(assess('web', device({ memoryGB: 0, gpu: true, gpuMaxBufferGB: 2, storageFreeGB: 20 }), ALL).recommended).toBe('balanced');
  });

  test('only tiers the host ships are offered', () => {
    const a = assess('macos', device({ memoryGB: 96, appleSilicon: true }), ['lite', 'balanced']);
    expect(a.recommended).toBe('balanced');
    expect(a.verdicts.map((v) => v.tier)).toEqual(['lite', 'balanced']);
  });

  test('a pick the device cannot run falls back to the recommended tier', () => {
    const a = assess('android', device({ memoryGB: 4, formFactor: 'phone' }), ALL);
    expect(effectiveTier(a, 'quality')).toBe('lite');
    expect(effectiveTier(a, 'auto')).toBe('lite');
    const big = assess('macos', device({ memoryGB: 96, appleSilicon: true }), ALL);
    expect(effectiveTier(big, 'lite')).toBe('lite');
  });
});

const longMeeting = (minutes: number): Segment[] =>
  Array.from({ length: minutes * 6 }, (_, i) => ({
    start: i * 10,
    end: i * 10 + 10,
    text: `Speaker ${i % 3} says point number ${i} about the roadmap, the budget, the hiring plan and the release schedule for next quarter.`,
  }));

describe('notes planning', () => {
  test('a short meeting is summarized in one request that carries the transcript and the person\'s notes', () => {
    const plan = planNotes(SIM_SEGMENTS, 'Ask about the login fix', 'lite');
    expect(plan.kind).toBe('oneShot');
    expect(stepCount(plan)).toBe(1);
    const request = stepRequest(plan, 0, [], 'Ask about the login fix');
    expect(request.prompt).toContain('[0:28] We launch on the fifteenth of March');
    expect(request.prompt).toContain('Ask about the login fix');
  });

  test('an hour-long meeting on Lite is read in parts, then merged', () => {
    const plan = planNotes(longMeeting(60), '', 'lite');
    expect(plan.kind).toBe('mapReduce');
    if (plan.kind !== 'mapReduce') return;
    expect(plan.chunks.length).toBeGreaterThan(3);
    expect(stepCount(plan)).toBe(plan.chunks.length + 1);
    const merge = stepRequest(plan, plan.chunks.length, ['- decided A', '- decided B'], '');
    expect(merge.prompt).toContain('Part 2:\n- decided B');
  });

  test('each part repeats the last line of the part before it', () => {
    const plan = planNotes(longMeeting(60), '', 'lite');
    if (plan.kind !== 'mapReduce') throw new Error('expected parts');
    const lastOfFirst = plan.chunks[0].split('\n').at(-1);
    expect(plan.chunks[1].split('\n')[0]).toBe(lastOfFirst);
  });

  test('the same hour fits one request on Quality', () => {
    expect(planNotes(longMeeting(60), '', 'quality').kind).toBe('oneShot');
  });

  test('a recording with no speech needs no model', () => {
    expect(planNotes([{ start: 0, end: 5, text: '  ' }], '', 'lite')).toEqual({ kind: 'empty' });
  });
});

describe('finishing notes', () => {
  test('the title line becomes the title and leaves the notes', () => {
    const notes = finishNotes('Title: Launch planning\n\n## Summary\nWe agreed.');
    expect(notes).toEqual({ title: 'Launch planning', markdown: '## Summary\nWe agreed.' });
  });

  test('reasoning blocks and code fences are removed', () => {
    const notes = finishNotes('<think>let me plan</think>\n```markdown\n**Title:** Sync\n## Summary\nShort.\n```');
    expect(notes).toEqual({ title: 'Sync', markdown: '## Summary\nShort.' });
  });

  test('a reply cut off inside its reasoning yields the no-speech notes, not the reasoning', () => {
    expect(finishNotes('<think>still thinking about').markdown).toContain('No speech was detected');
  });
});

const artifact = (id: string): Artifact => ({ id, runtime: 'sim', files: [] });

function harness(options: SimOptions = {}) {
  const engine = simEngine(options);
  const files = { transcript: [] as Segment[], aiNotes: '', userNotes: '' };
  const io: PipelineIO = {
    engine,
    stt: artifact('stt'),
    llm: artifact('llm'),
    readUserNotes: async () => files.userNotes,
    readTranscript: async () => files.transcript,
    writeTranscript: async (_m, segments) => void (files.transcript = segments),
    writeAiNotes: async (_m, markdown) => void (files.aiNotes = markdown),
  };
  const meeting: Meeting = {
    id: 'm1',
    title: '',
    createdAt: 0,
    durationS: 36,
    audio: 'app:/data/meetings/m1/audio.wav',
    tier: 'lite',
    stage: { kind: 'recorded' },
    attempt: 0,
  };
  const run = async (m: Meeting, limit = 50): Promise<{ meeting: Meeting; progress: number[] }> => {
    const progress: number[] = [];
    for (let i = 0; i < limit && isWorking(m); i++) {
      const next = await advance(m, io);
      m = next.meeting;
      progress.push(next.progress);
    }
    return { meeting: m, progress };
  };
  return { engine, files, io, meeting, run };
}

describe('the meeting pipeline', () => {
  test('a recorded meeting ends done with a transcript, AI notes and a title', async () => {
    const h = harness();
    const { meeting, progress } = await h.run(h.meeting);
    expect(meeting.stage).toEqual({ kind: 'done' });
    expect(meeting.title).toBe('Mobile app launch planning');
    expect(h.files.transcript).toEqual(SIM_SEGMENTS);
    expect(h.files.aiNotes.startsWith('## Summary')).toBe(true);
    expect(progress.at(-1)).toBe(1);
    expect(progress).toEqual([...progress].sort((a, b) => a - b));
  });

  test('a title the person typed is kept', async () => {
    const h = harness();
    const { meeting } = await h.run({ ...h.meeting, title: 'Weekly sync' });
    expect(meeting.title).toBe('Weekly sync');
  });

  test('a meeting whose engine restarted mid-transcription still finishes', async () => {
    const h = harness({ polls: 3 });
    let m = (await advance(h.meeting, h.io)).meeting;
    m = (await advance(m, h.io)).meeting;
    expect(m.stage.kind).toBe('transcribing');
    h.engine.forget();
    const { meeting } = await h.run(m);
    expect(meeting.stage).toEqual({ kind: 'done' });
    expect(h.files.transcript).toEqual(SIM_SEGMENTS);
  });

  test('a meeting whose engine restarted mid-summary still finishes', async () => {
    const h = harness({ polls: 1 });
    let m = h.meeting;
    while (m.stage.kind !== 'summarizing') m = (await advance(m, h.io)).meeting;
    h.engine.forget();
    const { meeting } = await h.run(m);
    expect(meeting.stage).toEqual({ kind: 'done' });
  });

  test('a failed transcription is reported with the engine\'s reason, and a retry finishes', async () => {
    const h = harness({ failJobsContaining: 'a0.stt' });
    const { meeting: stuck } = await h.run(h.meeting);
    expect(stuck.stage).toEqual({
      kind: 'failed',
      during: 'transcribing',
      error: 'The demo engine was told to fail this job.',
    });
    const { meeting } = await h.run(retry(stuck));
    expect(meeting.stage).toEqual({ kind: 'done' });
  });

  test('a failed summary keeps the transcript, and a retry only redoes the summary', async () => {
    const h = harness({ failJobsContaining: 'a0.notes' });
    const { meeting: stuck } = await h.run(h.meeting);
    expect(stuck.stage.kind).toBe('failed');
    expect(h.files.transcript).toEqual(SIM_SEGMENTS);
    const retried = retry(stuck);
    expect(retried.stage).toEqual({ kind: 'summarizing', job: '', step: 0, partials: [] });
    const { meeting } = await h.run(retried);
    expect(meeting.stage).toEqual({ kind: 'done' });
  });

  test('a finished or failed meeting is left alone', async () => {
    const h = harness();
    const done: Meeting = { ...h.meeting, stage: { kind: 'done' } };
    expect((await advance(done, h.io)).meeting).toBe(done);
  });
});

describe('engine replies', () => {
  test('a job reply is read into a view with progress clamped to 0..1', () => {
    expect(parseJobView({ id: 'j', state: 'running', progress: 4 })).toEqual({
      id: 'j', state: 'running', progress: 1, text: '', segments: [], error: '',
    });
  });

  test('a reply with no known state is refused', () => {
    expect(() => parseJobView({ id: 'j', state: 'finished' })).toThrow('no known state');
    expect(() => parseJobView('done')).toThrow('not an object');
  });
});
