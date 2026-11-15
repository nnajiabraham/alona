import { describe, expect, test } from 'bun:test';
import { memoryFiles } from '../core/fixtures/memory-files';
import { planNotes, stepRequest } from '../core/notes';
import { service } from '../core/service';
import { simEngine } from '../core/sim-engine';
import { meetingStore } from '../core/store';
import { defineTenant } from '../tenants/schema';
import tidewell from '../tenants/tidewell';
import { demoDraft, DEMO_CONSULTATION } from './lib/demo';
import { templateOf, templateProfile } from './lib/profile';
import { clinicService, profileFor } from './lib/service';
import base from '../tenants/default';

const headingsOf = (markdown: string): string[] => [...markdown.matchAll(/^## (.+)$/gm)].map((m) => m[1]);

function clinic(tenant = base) {
  const files = memoryFiles();
  const store = meetingStore(files);
  const engine = simEngine({ polls: 1, segments: DEMO_CONSULTATION, notes: demoDraft });
  const core = service(engine, store, 'Demo.', { profileOf: profileFor(store, tenant) });
  const c = clinicService(core, store, tenant);
  const settle = async (): Promise<void> => {
    for (let i = 0; i < 40; i++) await c.tick('');
  };
  const ready = async (): Promise<void> => {
    await c.downloadTier('balanced');
    for (let i = 0; i < 5; i++) await c.setup('');
  };
  return { c, core, files, store, settle, ready };
}

describe('a template as a notes profile', () => {
  const soap = templateOf(base, 'soap');
  const profile = templateProfile(soap, base);
  const prompt = stepRequest(profile, planNotes(DEMO_CONSULTATION, '- L knee', 'lite'), 0, [], '- L knee');

  test("the prompt asks for the template's sections in order, and no title", () => {
    expect(headingsOf(prompt.prompt.replace(/^"## (.+)": .*$/gm, '## $1'))).toEqual(['Subjective', 'Objective', 'Assessment', 'Plan']);
    expect(prompt.prompt).not.toContain('Title');
    expect(prompt.prompt).toContain("The clinician's own jottings from the consultation:\n- L knee");
  });

  test('the model is told never to add what was not said, to write "Not discussed." and to keep clinical wording', () => {
    expect(prompt.system).toContain('Never add findings, diagnoses, medications, doses, test results or plans that were not said.');
    expect(prompt.system).toContain("Keep the clinician's wording for clinical terms.");
    expect(prompt.prompt).toContain('Under a section with nothing said, write "Not discussed."');
  });

  test("the tenant's noun for the person is used", () => {
    const counselling = templateProfile(tidewell.templates[0], tidewell);
    expect(counselling.system).toContain('consultation with a client');
    expect(counselling.system).not.toContain('patient');
  });

  test('a recording with no speech still shows every section', () => {
    expect(headingsOf(profile.emptyResult)).toEqual(['Subjective', 'Objective', 'Assessment', 'Plan']);
    expect(profile.emptyResult).toContain('No speech was detected');
  });

  test('an unknown template id falls back to the default template', () => {
    expect(templateOf(base, 'retired').id).toBe('soap');
  });
});

describe('clinic notes', () => {
  test("a new note is drafted with its own template's sections and listed newest first", async () => {
    const { c, ready, settle } = clinic();
    await ready();
    await c.create('n1', '  Bed 4  ', 'consultation', 'app:/data/meetings/n1/audio.m4a', 44000, '', 100, 'balanced');
    await c.create('n2', '', 'soap', 'app:/data/meetings/n2/audio.m4a', 30000, '', 200, 'balanced');
    expect((await c.rows()).map((r) => r.state)).toEqual(['processing', 'processing']);
    await settle();
    const rows = await c.rows();
    expect(rows.map((r) => [r.id, r.patientRef, r.templateName, r.state])).toEqual([
      ['n2', 'No patient reference', 'SOAP', 'draft'],
      ['n1', 'Bed 4', 'General consultation', 'draft'],
    ]);
    const n1 = await c.detail('n1');
    expect(headingsOf(n1.note)).toEqual(['Reason for visit', 'History', 'Examination', 'Assessment', 'Plan', 'Follow-up']);
    expect(n1.segments.length).toBe(DEMO_CONSULTATION.length);
  });

  test("the clinician's edits are kept apart from the draft, and the pipeline never overwrites them", async () => {
    const { c, core, files, ready, settle } = clinic();
    await ready();
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    expect((await c.saveEdits('n1', 'too early')).ok).toBe(false);
    await settle();
    const draft = (await c.detail('n1')).draft;
    await c.saveEdits('n1', `${draft}\n\nChecked by me.`);
    // The pipeline writing the draft again (a retranscribe from Alona's service) leaves the edits alone.
    await core.retranscribe('n1');
    await settle();
    const d = await c.detail('n1');
    expect(d.hasEdits).toBe(true);
    expect(d.note).toBe(`${draft}\n\nChecked by me.`);
    expect(d.draft).toBe(draft);
    expect(files.paths().filter((p) => p.startsWith('app:/data/meetings/n1/'))).toEqual([
      'app:/data/meetings/n1/ai-notes.md', 'app:/data/meetings/n1/clinic.json', 'app:/data/meetings/n1/edited.md',
      'app:/data/meetings/n1/meeting.json', 'app:/data/meetings/n1/notes.md', 'app:/data/meetings/n1/stage.json',
      'app:/data/meetings/n1/transcript.json',
    ]);
  });

  test('writing again replaces the edits with a fresh draft', async () => {
    const { c, ready, settle } = clinic();
    await ready();
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    await settle();
    await c.saveEdits('n1', '## Subjective\nMine.');
    await c.writeAgain('n1');
    expect((await c.detail('n1')).state).toBe('processing');
    await settle();
    const d = await c.detail('n1');
    expect(d.hasEdits).toBe(false);
    expect(d.note).toBe(d.draft);
  });

  test('an edit that restores the draft exactly is not kept as an edit', async () => {
    const { c, ready, settle } = clinic();
    await ready();
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    await settle();
    await c.saveEdits('n1', 'x');
    await c.saveEdits('n1', (await c.detail('n1')).draft);
    expect((await c.detail('n1')).hasEdits).toBe(false);
  });

  test('marking reviewed records when, and an edit afterwards makes it a draft again', async () => {
    const { c, ready, settle } = clinic();
    await ready();
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    expect((await c.markReviewed('n1', 5)).ok).toBe(false);
    await settle();
    await c.markReviewed('n1', 1_700_000_000_000);
    let d = await c.detail('n1');
    expect([d.state, d.stateLabel, d.reviewedAt]).toEqual(['reviewed', 'Reviewed', 1_700_000_000_000]);
    await c.saveEdits('n1', `${d.note}\nOne more line.`);
    d = await c.detail('n1');
    expect([d.state, d.reviewedAt]).toEqual(['draft', 0]);
  });

  test('deleting a note removes its recording, transcript, draft, edits and review', async () => {
    const { c, files, ready, settle } = clinic();
    await ready();
    await files.atomicWriteFile('app:/data/meetings/n1/audio.m4a', new Uint8Array([1]));
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    await settle();
    await c.saveEdits('n1', 'mine');
    await c.markReviewed('n1', 9);
    await c.remove('n1');
    expect(files.paths().filter((p) => p.includes('/meetings/'))).toEqual([]);
    expect((await c.detail('n1')).found).toBe(false);
  });

  test("before the clinician picks a model tier, the tenant's default is used", async () => {
    const lite = defineTenant({ ...base, slug: 'lite-first', defaults: { template: 'soap', tier: 'lite' } });
    const { c } = clinic(lite);
    expect((await c.setup('')).active).toBe('lite');
    expect((await c.setup('balanced')).active).toBe('balanced');
  });
});

describe('writing a note again as another template', () => {
  async function reviewedConsultation() {
    const h = clinic();
    await h.ready();
    await h.files.atomicWriteFile('app:/data/meetings/n1/audio.m4a', new Uint8Array([7, 7]));
    await h.c.create('n1', 'Bed 4', 'consultation', 'app:/data/meetings/n1/audio.m4a', 44000, '- L knee', 100, 'balanced');
    await h.settle();
    await h.c.saveEdits('n1', `${(await h.c.detail('n1')).note}\nChecked.`);
    await h.c.markReviewed('n1', 500);
    return { ...h, first: await h.c.detail('n1') };
  }

  test('a referral letter sits beside the reviewed consultation note, same reference and recording, as an unreviewed draft', async () => {
    const { c, settle, first } = await reviewedConsultation();
    expect(await c.writeAs('n1', 'referral', 'n2')).toEqual({ ok: true, error: '' });
    expect((await c.detail('n2')).state).toBe('processing');
    await settle();
    const rows = await c.rows();
    expect(rows.map((r) => [r.id, r.patientRef, r.templateName, r.state]).sort()).toEqual([
      ['n1', 'Bed 4', 'General consultation', 'reviewed'],
      ['n2', 'Bed 4', 'Referral letter', 'draft'],
    ]);
    const second = await c.detail('n2');
    expect(headingsOf(second.note)).toEqual(['Reason for referral', 'History', 'Findings', 'Current treatment', 'Request']);
    expect([second.hasEdits, second.reviewedAt, second.writtenFrom, second.sharesRecording]).toEqual([false, 0, 'General consultation', true]);
    expect([second.audio, second.jottings, second.createdAt]).toEqual([first.audio, '- L knee', first.createdAt]);
    expect(second.segments).toEqual(first.segments);
    expect(await c.detail('n1')).toEqual({ ...first, sharesRecording: true });
  });

  test("the new note's edits and review are its own", async () => {
    const { c, settle, first } = await reviewedConsultation();
    await c.writeAs('n1', 'visit-summary', 'n2');
    await settle();
    await c.saveEdits('n2', 'Plain words.');
    await c.markReviewed('n2', 900);
    expect((await c.detail('n2')).state).toBe('reviewed');
    const again = await c.detail('n1');
    expect([again.note, again.state, again.reviewedAt]).toEqual([first.note, 'reviewed', 500]);
  });

  test('deleting either note keeps the recording the other plays', async () => {
    const one = await reviewedConsultation();
    await one.c.writeAs('n1', 'referral', 'n2');
    await one.settle();
    await one.c.remove('n2');
    expect((await one.c.detail('n1')).audio).toBe('app:/data/meetings/n1/audio.m4a');
    expect([...new Uint8Array(await one.files.readFile('app:/data/meetings/n1/audio.m4a'))]).toEqual([7, 7]);
    expect((await one.c.detail('n1')).sharesRecording).toBe(false);

    const two = await reviewedConsultation();
    await two.c.writeAs('n1', 'referral', 'n2');
    await two.settle();
    await two.c.remove('n1');
    const kept = await two.c.detail('n2');
    expect([...new Uint8Array(await two.files.readFile(kept.audio))]).toEqual([7, 7]);
    expect(kept.writtenFrom).toBe('General consultation');
  });

  test('an unknown template, a draft still being written, or an id in use is refused, and leaves nothing behind', async () => {
    const { c, files, ready } = clinic();
    await ready();
    await c.create('n1', 'A', 'soap', 'app:/data/meetings/n1/audio.m4a', 1000, '', 1, 'balanced');
    expect((await c.writeAs('n1', 'referral', 'n2')).ok).toBe(false);
    expect((await c.writeAs('n1', 'no-such', 'n2')).ok).toBe(false);
    expect((await c.writeAs('n1', 'referral', 'n1')).ok).toBe(false);
    expect((await c.writeAs('gone', 'referral', 'n2')).ok).toBe(false);
    expect(files.paths().filter((p) => p.includes('/n2/'))).toEqual([]);
  });
});

describe('the demo engine', () => {
  test('its draft has exactly the requested sections, so every template looks right in a demo build', () => {
    for (const template of [...base.templates, ...tidewell.templates]) {
      const prompt = stepRequest(templateProfile(template, base), planNotes(DEMO_CONSULTATION, '', 'lite'), 0, [], '').prompt;
      expect(headingsOf(demoDraft(prompt))).toEqual(template.sections.map((s) => s.heading));
    }
  });
});
