import { describe, expect, test } from 'bun:test';
import { assess, effectiveTier } from './device';
import type { Artifact, DeviceFacts } from './engine';
import { parseJobView } from './engine';
import { ALONA_NOTES, chatPrompt, finishNotes, planNotes, stepCount, stepRequest } from './notes';
import { advance, isWorking, retranscribe, retry, type PipelineIO } from './pipeline';
import { service } from './service';
import { meetingStore } from './store';
import { SIM_DEVICE, SIM_SEGMENTS, simEngine, type SimOptions } from './sim-engine';
import { displayTitle, type Meeting, type Segment } from './types';
import golden from './fixtures/alona-notes.golden.json';
import { planCases, rawReplies } from './fixtures/golden-inputs';
import type { NotesProfile } from './notes';
import { memoryFiles } from './fixtures/memory-files';
import { hostService } from './host';

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
      reason: 'Needs 6 GB of memory. This device has 4 GB.',
    });
  });

  test('a 12 GB phone stops at Balanced', () => {
    const a = assess('ios', device({ memoryGB: 12, formFactor: 'phone', appleSilicon: true }), ALL);
    expect(a.recommended).toBe('balanced');
    expect(a.verdicts.find((v) => v.tier === 'quality')?.reason).toBe('Too large for phones and tablets.');
  });

  test('an 8 GB Mac is told how much memory Quality needs', () => {
    const a = assess('macos', device({ memoryGB: 8, appleSilicon: true }), ALL);
    expect(a.recommended).toBe('balanced');
    expect(a.verdicts.find((v) => v.tier === 'quality')?.reason).toBe('Needs 16 GB of memory. This computer has 8 GB.');
  });

  test('a browser without WebGPU gets Lite and is told why', () => {
    const a = assess('web', device({ gpu: false }), ALL);
    expect(a.recommended).toBe('lite');
    expect(a.verdicts.find((v) => v.tier === 'balanced')?.reason).toBe('Needs WebGPU, which this browser does not have.');
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
    const request = stepRequest(ALONA_NOTES, plan, 0, [], 'Ask about the login fix');
    expect(request.prompt).toContain('[0:28] We launch on the fifteenth of March');
    expect(request.prompt).toContain('Ask about the login fix');
  });

  test('an hour-long meeting on Lite is read in parts, then merged', () => {
    const plan = planNotes(longMeeting(60), '', 'lite');
    expect(plan.kind).toBe('mapReduce');
    if (plan.kind !== 'mapReduce') return;
    expect(plan.chunks.length).toBeGreaterThan(3);
    expect(stepCount(plan)).toBe(plan.chunks.length + 1);
    const merge = stepRequest(ALONA_NOTES, plan, plan.chunks.length, ['- decided A', '- decided B'], '');
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

// The golden file was written by notes.ts as it was before note formats became
// profiles (commit a378354), so these prove Alona's prompts and notes did not change.
describe("Alona's notes profile", () => {
  test('every request Alona sends is the same as before profiles', () => {
    for (const c of planCases) {
      const plan = planNotes(c.segments, c.userNotes, c.tier);
      const expected = golden.plans.find((p) => p.name === c.name);
      expect(plan.kind).toBe(expected?.kind ?? '');
      const partials = Array.from({ length: stepCount(plan) }, (_, i) => `- fact ${i}`);
      const requests = partials.map((_, i) => {
        const r = stepRequest(ALONA_NOTES, plan, i, partials.slice(0, i), c.userNotes);
        return { ...r, chat: chatPrompt(r) };
      });
      expect(requests).toEqual(expected?.requests ?? []);
    }
  });

  test('every reply is finished into the same notes as before profiles', () => {
    expect(rawReplies.map((raw) => ({ raw, notes: finishNotes(ALONA_NOTES, raw) }))).toEqual(golden.finished);
    expect(ALONA_NOTES.emptyResult).toBe(golden.noSpeech);
  });
});

describe('another notes profile', () => {
  const visit: NotesProfile = {
    ...ALONA_NOTES,
    recording: 'consultation',
    intro: 'Write the consultation note in Markdown.',
    titleRule: '',
    sections: [
      { heading: 'Reason (for visit)', guidance: 'why the patient came.' },
      { heading: 'Plan', guidance: 'what was agreed next.' },
    ],
    closing: 'Under a section with nothing said, write "Not discussed."',
    missingSection: 'Not discussed.',
    extractHeadings: ['Reason (for visit)', 'Plan'],
    ownNotesLabel: "The clinician's jottings:",
  };
  const short: Segment[] = [{ start: 0, end: 4, text: 'My knee hurts.' }];

  test('the prompt lists its own sections, in order, with no title line', () => {
    const r = stepRequest(visit, planNotes(short, '- left knee', 'lite'), 0, [], '- left knee');
    expect(r.prompt).toStartWith('Write the consultation note in Markdown.\n\nWrite these two sections in this order.');
    expect(r.prompt).toContain('"## Reason (for visit)": why the patient came.\n"## Plan": what was agreed next.\n\nUnder a section');
    expect(r.prompt).not.toContain('Title');
    expect(r.prompt).toEndWith("The clinician's jottings:\n- left knee");
  });

  test('long recordings are read for its own headings', () => {
    const long = Array.from({ length: 200 }, (_, i) => ({ start: i, end: i + 1, text: 'word '.repeat(20) }));
    const r = stepRequest(visit, planNotes(long, '', 'lite'), 0, [], '');
    expect(r.prompt).toContain('of a consultation transcript');
    expect(r.prompt).toContain('Reason (for visit):\nPlan:\n');
  });

  test('a missing section, even one with brackets in its heading, is added with its own empty text', () => {
    expect(finishNotes(visit, '## Plan\nRest.').markdown).toBe('## Plan\nRest.\n\n## Reason (for visit)\nNot discussed.');
    expect(finishNotes(visit, '## Reason (for visit)\nKnee.\n## Plan\nRest.').markdown).toBe('## Reason (for visit)\nKnee.\n## Plan\nRest.');
  });
});

describe('finishing notes', () => {
  test('the title line becomes the title and leaves the notes', () => {
    const notes = finishNotes(ALONA_NOTES, 'Title: Launch planning\n\n## Summary\nWe agreed.');
    expect(notes.title).toBe('Launch planning');
    expect(notes.markdown.startsWith('## Summary\nWe agreed.')).toBe(true);
  });

  test('a section the model left out is added and says nothing was recorded', () => {
    const { markdown } = finishNotes(ALONA_NOTES, 'Title: Sync\n## Summary\nShort.\n\n## Key points\n- One\n\n## Decisions\n- Ship\n\n## Action items\n- [ ] Ana: ship');
    expect(markdown.endsWith('## Action items\n- [ ] Ana: ship\n\n## Open questions\n- None recorded.')).toBe(true);
    expect(markdown.match(/^## /gm)?.length).toBe(5);
  });

  test('sections the model wrote are never duplicated', () => {
    const full = '## Summary\nA.\n## Key points\n- b\n## Decisions\n- c\n## Action items\n- d\n## Open questions\n- e';
    expect(finishNotes(ALONA_NOTES, full).markdown).toBe(full);
  });

  test('reasoning blocks and code fences are removed', () => {
    const notes = finishNotes(ALONA_NOTES, '<think>let me plan</think>\n```markdown\n**Title:** Sync\n## Summary\nShort.\n```');
    expect(notes.title).toBe('Sync');
    expect(notes.markdown.startsWith('## Summary\nShort.')).toBe(true);
  });

  test('a first-level heading is taken as the title when no title line is given', () => {
    expect(finishNotes(ALONA_NOTES, '# Launch planning\n\n## Summary\nWe agreed.').title).toBe('Launch planning');
  });

  test('a title that only repeats the instruction is dropped, so the meeting keeps its own name', () => {
    expect(finishNotes(ALONA_NOTES, '# a short title for the meeting, on one line\n\n## Summary\nWe agreed.').title).toBe('');
    expect(finishNotes(ALONA_NOTES, 'Title: names what this meeting was about in three to six words\n## Summary\nOk.').title).toBe('');
  });

  test('a reply cut off inside its reasoning yields the no-speech notes, not the reasoning', () => {
    expect(finishNotes(ALONA_NOTES, '<think>still thinking about').markdown).toContain('No speech was detected');
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
    profile: ALONA_NOTES,
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
    suggestedTitle: '',
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
    expect(displayTitle(meeting)).toBe('Sample notes');
    expect(h.files.transcript).toEqual(SIM_SEGMENTS);
    expect(h.files.aiNotes).toContain('## Summary');
    expect(progress.at(-1)).toBe(1);
    expect(progress).toEqual([...progress].sort((a, b) => a - b));
  });

  test('a title the person typed is kept', async () => {
    const h = harness();
    const { meeting } = await h.run({ ...h.meeting, title: 'Weekly sync' });
    expect(displayTitle(meeting)).toBe('Weekly sync');
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
    expect(retried.stage).toEqual({ kind: 'summarizing', job: '', step: 0, steps: 0, partials: [] });
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

describe('model downloads', () => {
  function app(options: SimOptions = {}) {
    const files = memoryFiles();
    const engine = simEngine(options);
    return Object.assign(service(engine, meetingStore(files), 'Demo.'), { engine, files });
  }

  test('a tier is not installed until its download finishes, then stays installed', async () => {
    const s = app({ polls: 2 });
    expect((await s.setup('auto')).activeInstalled).toBe(false);
    await s.downloadTier('balanced');
    expect((await s.setup('auto')).activeDownloading).toBe(true);
    await s.setup('auto');
    const done = await s.setup('auto');
    expect(done.activeInstalled).toBe(true);
    expect(done.activeDownloading).toBe(false);
  });

  test('a removed tier reads as not installed and can be downloaded again', async () => {
    const s = app({ polls: 1 });
    await s.downloadTier('lite');
    await s.setup('lite');
    expect((await s.setup('lite')).activeInstalled).toBe(true);
    await s.removeTier('lite');
    expect((await s.setup('lite')).activeInstalled).toBe(false);
    await s.downloadTier('lite');
    await s.setup('lite');
    expect((await s.setup('lite')).activeInstalled).toBe(true);
  });

  test('a pick this device cannot run falls back to the recommended tier', async () => {
    const s = app({ device: { ...SIM_DEVICE, gpu: false } });
    const setup = await s.setup('quality');
    expect(setup.active).toBe('lite');
    expect(setup.tiers.find((t) => t.id === 'quality')?.reason).toBe('Too large for a browser. The desktop app can run it.');
  });

  test('a recorded meeting waits while its tier\'s models are missing, then runs once they arrive', async () => {
    const s = app({ polls: 1 });
    await s.create('m1', '', 'app:/data/meetings/m1/audio.wav', 5000, 'my note', 1000, 'balanced');
    await s.tick('auto');
    expect((await s.rows())[0].status).toBe('recorded');
    await s.downloadTier('balanced');
    await s.setup('auto');
    for (let i = 0; i < 12; i++) await s.tick('auto');
    const detail = await s.detail('m1');
    expect(detail.status).toBe('done');
    expect(detail.title).toBe('Sample notes');
    expect(detail.userNotes).toBe('my note');
    expect(detail.segments[1]).toEqual({ id: '1', at: '0:07', text: SIM_SEGMENTS[1].text });
  });

  test('the model is released when the last queued meeting finishes, not between meetings', async () => {
    const s = app({ polls: 1 });
    await s.downloadTier('balanced');
    await s.setup('auto');
    await s.create('m1', 'One', 'app:/data/meetings/m1/audio.wav', 5000, '', 1000, 'balanced');
    await s.create('m2', 'Two', 'app:/data/meetings/m2/audio.wav', 5000, '', 2000, 'balanced');
    let ticks = 0;
    while ((await s.tick('auto')).working && ticks++ < 40) {
      const done = (await s.rows()).filter((r) => r.status === 'done').length;
      if (done < 2) expect(s.engine.unloadCount()).toBe(0);
    }
    expect((await s.rows()).map((r) => r.status)).toEqual(['done', 'done']);
    expect(s.engine.unloadCount()).toBe(1);
  });

  test('a download that failed can be started again', async () => {
    const s = app({ polls: 1 });
    await s.downloadTier('lite');
    await s.engine.cancel('dl.demo-lite-stt');
    expect((await s.engine.job('dl.demo-lite-stt')).state).toBe('failed');
    await s.downloadTier('lite');
    expect((await s.engine.job('dl.demo-lite-stt')).state).not.toBe('failed');
    await s.setup('lite');
    expect((await s.setup('lite')).activeInstalled).toBe(true);
  });

  test('notes for a meeting that does not exist are refused and leave the library readable', async () => {
    const s = app();
    await s.create('m1', 'One', 'app:/data/meetings/m1/audio.wav', 5000, '', 1000, 'lite');
    expect(await s.saveNotes('', 'lost draft')).toEqual({ ok: false, error: 'That meeting is gone.' });
    expect(await s.saveNotes('../m1', 'x')).toEqual({ ok: false, error: 'That meeting is gone.' });
    expect((await s.rows()).map((r) => r.title)).toEqual(['One']);
  });

  test('a recording left without a meeting record is recovered at launch', async () => {
    const s = app();
    await s.files.atomicWriteFile('app:/data/meetings/m1700000000000/audio.m4a', new Uint8Array([1]));
    const rows = await s.rows();
    expect(rows.map((r) => [r.id, r.title, r.status])).toEqual([['m1700000000000', 'Recovered recording', 'recorded']]);
    expect((await s.detail('m1700000000000')).audio).toBe('app:/data/meetings/m1700000000000/audio.m4a');
  });

  test('a recording that starts after launch is not adopted while it is in progress', async () => {
    const s = app();
    expect(await s.rows()).toEqual([]);
    await s.files.atomicWriteFile('app:/data/meetings/m2/audio.m4a', new Uint8Array([1]));
    expect(await s.rows()).toEqual([]);
  });

  test('deleting a meeting removes it from the library', async () => {
    const s = app();
    await s.create('m1', 'One', 'app:/data/meetings/m1/audio.wav', 5000, '', 1000, 'lite');
    await s.create('m2', 'Two', 'app:/data/meetings/m2/audio.wav', 5000, '', 2000, 'lite');
    expect((await s.rows()).map((r) => r.title)).toEqual(['Two', 'One']);
    await s.remove('m1');
    expect((await s.rows()).map((r) => r.title)).toEqual(['Two']);
    expect((await s.detail('m1')).found).toBe(false);
  });
});

describe('a plan that changes mid-summary', () => {
  test('notes edited during a long summary restart it, so one part is never taken for the whole', async () => {
    const h = harness({ polls: 1 });
    let m: Meeting = { ...h.meeting, stage: { kind: 'recorded' } };
    while (m.stage.kind !== 'summarizing') m = (await advance(m, h.io)).meeting;
    h.files.transcript = longMeeting(60);
    m = (await advance({ ...m, stage: { kind: 'summarizing', job: '', step: 0, steps: 0, partials: [] } }, h.io)).meeting;
    m = (await advance(m, h.io)).meeting;
    expect(m.stage.kind === 'summarizing' && m.stage.steps > 2).toBe(true);
    const attempt = m.attempt;
    h.files.transcript = SIM_SEGMENTS;
    m = (await advance(m, h.io)).meeting;
    expect(m.stage).toMatchObject({ kind: 'summarizing', step: 0, steps: 1, partials: [] });
    expect(m.attempt).toBe(attempt + 1);
    const { meeting } = await h.run(m);
    expect(meeting.stage).toEqual({ kind: 'done' });
  });
});

describe('running a meeting again', () => {
  test('transcribing again replaces the transcript and the notes', async () => {
    const h = harness({ polls: 1 });
    const { meeting: first } = await h.run(h.meeting);
    h.files.transcript = [];
    h.files.aiNotes = '';
    const again = retranscribe(first);
    expect(again.stage).toEqual({ kind: 'recorded' });
    const { meeting } = await h.run(again);
    expect(meeting.stage).toEqual({ kind: 'done' });
    expect(h.files.transcript).toEqual(SIM_SEGMENTS);
    expect(h.files.aiNotes).toContain('## Summary');
  });

  test('a meeting still being processed is not restarted', () => {
    const h = harness();
    expect(retranscribe(h.meeting)).toBe(h.meeting);
  });
});

describe('a service with its own note format', () => {
  const plan: NotesProfile = {
    ...ALONA_NOTES,
    titleRule: '',
    sections: [{ heading: 'Plan', guidance: 'what happens next.' }],
    missingSection: 'Not discussed.',
  };

  test('each meeting is written in the format the app picks for it, and the engine is given that format', async () => {
    const prompts: string[] = [];
    const engine = simEngine({ polls: 1, notes: (prompt) => (prompts.push(prompt), '## Summary\nSaid things.') });
    const store = meetingStore(memoryFiles());
    const s = service(engine, store, 'Demo.', { profileOf: async (m) => (m.title === 'plan' ? plan : ALONA_NOTES) });
    await s.downloadTier('balanced');
    for (let i = 0; i < 5; i++) await s.setup('auto');
    await s.create('a', 'plan', 'app:/data/meetings/a/audio.wav', 1000, '', 1, 'balanced');
    await s.create('b', 'alona', 'app:/data/meetings/b/audio.wav', 1000, '', 2, 'balanced');
    for (let i = 0; i < 30; i++) await s.tick('auto');
    expect(prompts.some((p) => p.includes('"## Plan": what happens next.') && !p.includes('Key points'))).toBe(true);
    expect((await s.detail('a')).aiNotes).toBe('## Summary\nSaid things.\n\n## Plan\nNot discussed.');
    expect((await s.detail('b')).aiNotes).toContain('## Open questions\n- None recorded.');
  });

  test("an app's own files sit beside a meeting's, and the store's own names are refused", async () => {
    const files = memoryFiles();
    const store = meetingStore(files);
    await store.writeExtra('a', 'review.json', '{}');
    expect(await store.readExtra('a', 'review.json')).toBe('{}');
    expect(await store.readExtra('a', 'edited.md')).toBe('');
    expect(() => store.writeExtra('a', 'ai-notes.md', 'x')).toThrow('not a file an app may add');
    expect(() => store.writeExtra('a', '../b/notes.md', 'x')).toThrow('not a file an app may add');
    await store.remove('a');
    expect(files.paths()).toEqual([]);
  });
});

describe('choosing the engine at launch', () => {
  test('without a native module, the demo engine answers and says why', async () => {
    const { service: s } = await hostService(memoryFiles(), null, { sampleLine: 'Samples.' });
    const setup = await s.setup('auto');
    expect([setup.demo, setup.demoNote]).toEqual([true, 'This build has no on-device models. Samples.']);
  });

  test("Android's recording-only module fails the probe, so the demo engine runs as a phone", async () => {
    const native = { available: true, later: async () => ({ error: 'NotSupportedError' }) };
    const setup = await (await hostService(memoryFiles(), native)).service.setup('auto');
    expect(setup.demo).toBe(true);
    expect(setup.demoNote).toStartWith('The Android app has no on-device models.');
  });

  test('a native engine that answers its probe is used, with no demo note', async () => {
    const replies: Record<string, unknown> = {
      probe: { ...SIM_DEVICE, host: 'macos', memoryGB: 32, appleSilicon: true },
      installed: { ids: [] },
      job: { id: 'j', state: 'unknown' },
    };
    const native = { available: true, later: async (r: Record<string, unknown>) => replies[String(r.op)] ?? {} };
    const setup = await (await hostService(memoryFiles(), native)).service.setup('auto');
    expect([setup.demo, setup.demoNote]).toEqual([false, '']);
  });
});
