import { defineTenant } from './schema';

// An invented counselling practice: warm amber, "client" rather than "patient".
export default defineTenant({
  slug: 'tidewell',
  app: {
    name: 'Tidewell Session Notes',
    shortName: 'Tidewell',
    tagline: 'Session notes for counsellors, kept on your device.',
    bundleId: 'app.tidewell.sessionnotes',
    version: '0.1.0',
  },
  colors: {
    accent: { light: '#9a4a12', dark: '#b8611f' },
    page: { light: '#faf6f1', dark: '#1a1511' },
    card: { light: '#f1e9df', dark: '#261f19' },
    raised: { light: '#fffdfa', dark: '#2e2620' },
    line: { light: '#e3d7c8', dark: '#3a3028' },
    text: { light: '#2a1d14', dark: '#f0e8df' },
    muted: { light: '#66564a', dark: '#b8aa9c' },
    progressSoft: { light: '#f5e3d2', dark: '#3a2a1c' },
    progressInk: { light: '#7a3a0c', dark: '#f0bf92' },
    attentionSoft: { light: '#f6dedd', dark: '#3d2121' },
    attentionInk: { light: '#8f2d2a', dark: '#f0a6a2' },
    noticeSoft: { light: '#e8ecd8', dark: '#2a2f1e' },
    noticeInk: { light: '#4c5a17', dark: '#c9d68f' },
  },
  copy: {
    welcomeTitle: 'Session notes, private by design',
    welcomeBody: 'Record a session with consent, then review a draft note written on this device. Nothing about your clients leaves it.',
    person: { singular: 'client', plural: 'clients' },
    reviewDisclaimer: 'Draft written by an on-device model. Read it in full and correct it before it becomes your note.',
    privacy: 'Recordings, transcripts and notes are processed and stored on this device. The app connects to the internet only to download its models, and sends no analytics.',
  },
  templates: [
    {
      id: 'session',
      name: 'Session note',
      description: 'Themes, interventions, risk and next steps.',
      sections: [
        { heading: 'Presenting themes', guidance: 'What the client brought to the session, in their words where possible.' },
        { heading: 'Interventions', guidance: 'Approaches or exercises the counsellor used in this session.' },
        { heading: 'Risk', guidance: 'Any risk the client or counsellor named and what was agreed about it.' },
        { heading: 'Next steps', guidance: 'Homework, next session date or referrals that were agreed.' },
      ],
    },
    {
      id: 'dap',
      name: 'DAP',
      description: 'Data, assessment and plan.',
      sections: [
        { heading: 'Data', guidance: 'What the client said and what the counsellor observed.' },
        { heading: 'Assessment', guidance: "The counsellor's stated reading of the session." },
        { heading: 'Plan', guidance: 'What happens before and at the next session.' },
      ],
    },
  ],
  defaults: { template: 'session', tier: 'auto' },
  features: { jottings: true, copy: true, share: true, playback: true },
  support: { email: 'help@tidewell.example', url: 'https://tidewell.example/help' },
  icon: 'icons/tidewell.png',
});
