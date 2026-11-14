import type { NotesProfile } from '../../core/notes';
import type { NoteTemplate, TenantConfig } from '../../tenants/schema';

export const NOT_DISCUSSED = 'Not discussed.';

/** The clinical rules every template's prompts carry. */
const rules = (person: string): string =>
  `Use only what was said in the consultation and the clinician's jottings. Never add findings, diagnoses, medications, doses, test results or plans that were not said. Keep the clinician's wording for clinical terms. Do not guess names, numbers, dates or the ${person}'s details.`;

/** The notes profile a template's draft is written with. */
export function templateProfile(template: NoteTemplate, tenant: Pick<TenantConfig, 'copy'>): NotesProfile {
  const person = tenant.copy.person.singular;
  const headings = template.sections.map((s) => s.heading);
  return {
    recording: 'consultation',
    system: `You write a clinician's draft ${template.name} note from the transcript of a consultation with a ${person}. ${rules(person)} The clinician reviews the draft before it is used. Reply with the note only, in the consultation's language.`,
    extractSystem: `You extract facts from one part of a consultation transcript. ${rules(person)} Reply with short bullets only.`,
    intro: `Write the ${template.name} note in Markdown.`,
    titleRule: '',
    sections: template.sections.map((s) => ({ heading: s.heading, guidance: s.guidance })),
    closing: `Under each heading, write only what was said about it, in short sentences or bullets. Under a section with nothing said, write "${NOT_DISCUSSED}" Write no other headings.`,
    missingSection: NOT_DISCUSSED,
    extractHeadings: headings,
    emptyResult: ['> No speech was detected in this recording.', ...headings.map((h) => `## ${h}\n${NOT_DISCUSSED}`)].join('\n\n'),
    ownNotesLabel: "The clinician's own jottings from the consultation:",
  };
}

/** The tenant's template with this id, or its default template when none has it. */
export function templateOf(tenant: TenantConfig, id: string): NoteTemplate {
  const fallback = tenant.templates.find((t) => t.id === tenant.defaults.template) ?? tenant.templates[0];
  return tenant.templates.find((t) => t.id === id) ?? fallback;
}
