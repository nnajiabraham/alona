import { defineTenant } from './schema';

// A test partner: an invented physiotherapy group piloting the app.
export default defineTenant({
  slug: 'quillmoor-pilot',
  app: {
    name: 'Quillmoor Notes',
    shortName: 'Quillmoor',
    tagline: 'Pilot build for Quillmoor Physio. Treatment notes from your sessions.',
    bundleId: 'test.quillmoor.notes',
    version: '0.1.0',
  },
  colors: {
    accent: { light: '#5b3fa0', dark: '#7a5cc4' },
    page: { light: '#f6f4fb', dark: '#141220' },
    card: { light: '#ebe7f5', dark: '#1e1b2d' },
    raised: { light: '#fdfcff', dark: '#262238' },
    line: { light: '#d9d3ea', dark: '#332e48' },
    text: { light: '#1d1830', dark: '#e9e6f3' },
    muted: { light: '#585170', dark: '#aca6c2' },
    progressSoft: { light: '#e4ddf5', dark: '#2a2342' },
    progressInk: { light: '#46307f', dark: '#c4b5ef' },
    attentionSoft: { light: '#f7dfe4', dark: '#3b1f27' },
    attentionInk: { light: '#8e2440', dark: '#f0a2b5' },
    noticeSoft: { light: '#f3e9d0', dark: '#352d1c' },
    noticeInk: { light: '#6a4f0c', dark: '#e0c482' },
  },
  copy: {
    welcomeTitle: 'Welcome to the Quillmoor pilot',
    welcomeBody: 'Record a treatment session and Quillmoor Notes drafts the treatment note on this phone. You review every draft before it goes into the record.',
    person: { singular: 'patient', plural: 'patients' },
    reviewDisclaimer: 'This is a pilot build. Review and correct the draft before you copy it into the patient record.',
    privacy: 'Session audio, transcripts and notes are processed and stored on this device only. Nothing is sent to Quillmoor or anyone else; the app downloads its models once.',
  },
  templates: [
    {
      id: 'physio-initial',
      name: 'Initial assessment',
      description: 'First session: history, findings and a treatment plan.',
      sections: [
        { heading: 'Presenting complaint', guidance: 'The problem the patient came with, its onset and what makes it better or worse.' },
        { heading: 'History', guidance: 'Past episodes, general health and activity the patient described.' },
        { heading: 'Findings', guidance: 'Range of movement, strength and tests the clinician reported aloud.' },
        { heading: 'Impression', guidance: "The clinician's stated working impression." },
        { heading: 'Treatment plan', guidance: 'Exercises, treatment and advice given, with frequency if said.' },
      ],
    },
    {
      id: 'physio-follow-up',
      name: 'Follow-up session',
      description: 'Progress since last time and what changes now.',
      sections: [
        { heading: 'Progress', guidance: 'How the patient said they have been since the last session.' },
        { heading: 'Treatment today', guidance: 'What was done in this session.' },
        { heading: 'Plan', guidance: 'Changes to exercises or treatment, and when to return.' },
      ],
    },
  ],
  defaults: { template: 'physio-initial', tier: 'lite' },
  features: { jottings: true, copy: true, share: false, playback: false },
  support: { email: 'pilot-support@quillmoor.test', hours: 'Pilot support: weekdays 9:00 to 17:00' },
  icon: 'icons/quillmoor-pilot.png',
});
