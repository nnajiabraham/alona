import { defineTenant } from './schema';

// The neutral build: no organization's name, a calm teal on cool grays.
export default defineTenant({
  slug: 'default',
  app: {
    name: 'Clinic Notes',
    shortName: 'Clinic Notes',
    tagline: 'Visit notes, drafted on this device.',
    bundleId: 'app.clinicnotes.default',
    version: '0.1.1',
  },
  colors: {
    accent: { light: '#1f6f6b', dark: '#2f8a84' },
    page: { light: '#f3f5f5', dark: '#121716' },
    card: { light: '#e6ebea', dark: '#1c2322' },
    raised: { light: '#fbfcfc', dark: '#232b2a' },
    line: { light: '#d3dbda', dark: '#2d3736' },
    text: { light: '#17201f', dark: '#e3e9e8' },
    muted: { light: '#4f5d5b', dark: '#a0aead' },
    progressSoft: { light: '#d9ebe8', dark: '#1d3331' },
    progressInk: { light: '#1a5753', dark: '#9fd3cc' },
    attentionSoft: { light: '#f5e0dc', dark: '#3a2522' },
    attentionInk: { light: '#8c3426', dark: '#eba597' },
    noticeSoft: { light: '#efe7d2', dark: '#332e20' },
    noticeInk: { light: '#6e5512', dark: '#dcc37f' },
  },
  copy: {
    welcomeTitle: 'Clinic Notes',
    welcomeBody: 'Record a consultation and get a draft note to review. Audio, transcripts and notes stay on this device.',
    person: { singular: 'patient', plural: 'patients' },
    reviewDisclaimer: 'Check every line against the consultation before you use it.',
    privacy: 'Recordings, transcripts and notes are processed and stored on this device. The app goes online only to download its models. It sends no analytics and no logs.',
  },
  templates: [
    {
      id: 'soap',
      name: 'SOAP',
      description: 'Subjective, objective, assessment and plan.',
      sections: [
        { heading: 'Subjective', guidance: "What the patient reported: symptoms, history and concerns, in the patient's words where possible." },
        { heading: 'Objective', guidance: 'What the clinician observed or measured during the consultation, exactly as stated.' },
        { heading: 'Assessment', guidance: "The clinician's stated impression; never a diagnosis the clinician did not say." },
        { heading: 'Plan', guidance: 'Treatment, advice, referrals and follow-up the clinician said, with any timing given.' },
      ],
    },
    {
      id: 'consultation',
      name: 'General consultation',
      description: 'Reason for visit through to follow-up.',
      sections: [
        { heading: 'Reason for visit', guidance: 'Why the patient came, in one or two sentences.' },
        { heading: 'History', guidance: 'Relevant history the patient or clinician described.' },
        { heading: 'Examination', guidance: 'Examination findings the clinician said aloud.' },
        { heading: 'Assessment', guidance: "The clinician's stated impression." },
        { heading: 'Plan', guidance: 'What was agreed: treatment, advice and tests.' },
        { heading: 'Follow-up', guidance: 'When and how the patient will be seen again.' },
      ],
    },
    {
      id: 'dictation',
      name: 'Dictated note',
      description: 'You dictate after the visit; the app tidies it into a note.',
      sections: [
        { heading: 'Summary', guidance: 'The visit in two or three sentences, as the clinician dictated it.' },
        { heading: 'Findings', guidance: 'History and examination findings the clinician dictated.' },
        { heading: 'Plan', guidance: 'The plan the clinician dictated, with any timing given.' },
      ],
    },
    {
      id: 'referral',
      name: 'Referral letter',
      description: 'A letter to another clinician, from what was said in the visit.',
      sections: [
        { heading: 'Reason for referral', guidance: 'What the referring clinician asks the other clinician to assess or do.' },
        { heading: 'History', guidance: 'The relevant history the patient or clinician described.' },
        { heading: 'Findings', guidance: 'Examination findings and results the clinician said aloud.' },
        { heading: 'Current treatment', guidance: 'Treatment and medication mentioned in the visit, exactly as stated.' },
        { heading: 'Request', guidance: 'What the clinician asked for and how soon, if a timing was given.' },
      ],
    },
    {
      id: 'visit-summary',
      name: 'Visit summary for the patient',
      description: 'Plain-language instructions the patient can take home.',
      sections: [
        { heading: 'What we talked about', guidance: 'The visit in plain words, without clinical jargon.' },
        { heading: 'What to do now', guidance: 'Each instruction the clinician gave, as a short step.' },
        { heading: 'When to get help', guidance: 'Any warning signs or reasons to come back that the clinician said.' },
        { heading: 'Next appointment', guidance: 'When the patient will be seen again, if it was said.' },
      ],
    },
  ],
  defaults: { template: 'soap', tier: 'auto' },
  features: { jottings: true, copy: true, share: true, playback: true },
  icon: 'icons/default.png',
});
