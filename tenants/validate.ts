import { COLOR_TOKENS, type ColorToken, type TenantConfig } from './schema';

/** One rule a tenant config breaks: the field, what is wrong, and how to fix it. */
export interface Problem {
  field: string;
  message: string;
}

const HEX = /^#[0-9a-fA-F]{6}$/;
const ID = /^[a-z][a-z0-9-]*$/;
const BUNDLE = /^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*){2,}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const VERSION = /^\d+\.\d+\.\d+$/;

/** WCAG 2 relative luminance of a `#rrggbb` colour. */
function luminance(hex: string): number {
  const channel = (i: number): number => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
}

export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** Text on the surfaces the views put it on, at 4.5 to 1. */
const TEXT_PAIRS: [ColorToken, ColorToken][] = [
  ['text', 'page'], ['text', 'card'], ['text', 'raised'],
  ['muted', 'page'], ['muted', 'card'], ['muted', 'raised'],
  ['progressInk', 'progressSoft'], ['attentionInk', 'attentionSoft'], ['noticeInk', 'noticeSoft'],
];

/** Icons and the accent's marks on the page, at 3 to 1. */
const MARK_PAIRS: [ColorToken, ColorToken][] = [['accent', 'page'], ['accent', 'card']];

const WHITE = '#ffffff';
const BLACK = '#000000';

/** The longest word the welcome title can hold at the largest text size on a 390-point-wide phone. */
const TITLE_WORD = 8;

/**
 * What the types cannot say about a tenant. `fileExists` answers for paths
 * relative to tenants/; `slug` is the file's name, which the config's slug must match.
 */
export function validateTenant(t: TenantConfig, slug: string, fileExists: (path: string) => boolean): Problem[] {
  const problems: Problem[] = [];
  const add = (field: string, message: string): void => void problems.push({ field, message });

  if (t.slug !== slug) add('slug', `is "${t.slug}" but the file is tenants/${slug}.ts. Make them the same.`);

  const text: [string, string][] = [
    ['app.name', t.app.name], ['app.shortName', t.app.shortName], ['app.tagline', t.app.tagline],
    ['copy.welcomeTitle', t.copy.welcomeTitle], ['copy.welcomeBody', t.copy.welcomeBody],
    ['copy.person.singular', t.copy.person.singular], ['copy.person.plural', t.copy.person.plural],
    ['copy.reviewDisclaimer', t.copy.reviewDisclaimer], ['copy.privacy', t.copy.privacy],
  ];
  for (const [field, value] of text) if (value.trim() === '') add(field, 'is empty. Write the text the app shows.');
  const long = t.copy.welcomeTitle.split(/[^\p{L}\p{N}'-]+/u).find((w) => [...w].length > TITLE_WORD);
  if (long !== undefined) {
    add('copy.welcomeTitle', `has "${long}", longer than ${TITLE_WORD} letters, which spills off a phone at the largest text size. Rephrase it with shorter words; the app's name can go in copy.welcomeBody.`);
  }
  if (t.app.shortName.length > 12) add('app.shortName', `is ${t.app.shortName.length} characters. Shorten it to 12 or fewer, so it fits under the icon.`);
  if (!BUNDLE.test(t.app.bundleId)) {
    add('app.bundleId', `"${t.app.bundleId}" is not a reverse-DNS id. Use lowercase words joined by dots, at least three, such as "org.example.notes".`);
  }
  if (!VERSION.test(t.app.version)) add('app.version', `"${t.app.version}" is not a version. Write three numbers, such as "1.0.0".`);
  for (const [field, value] of [['copy.person.singular', t.copy.person.singular], ['copy.person.plural', t.copy.person.plural]] as const) {
    if (value !== value.toLowerCase()) add(field, `"${value}" has capitals. Write it in lowercase; the app capitalizes it where a sentence starts.`);
  }
  if (/\b(hipaa|gdpr|compliant|compliance|certified)\b/i.test(t.copy.privacy)) {
    add('copy.privacy', 'claims a regulation or certification. Say what the app does (it processes and stores on this device) and leave compliance claims out.');
  }

  for (const token of COLOR_TOKENS) {
    for (const scheme of ['light', 'dark'] as const) {
      const value = t.colors[token][scheme];
      if (!HEX.test(value)) add(`colors.${token}.${scheme}`, `"${value}" is not a colour. Write six hex digits, such as "#1f6f6b".`);
    }
  }
  const valid = (token: ColorToken, scheme: 'light' | 'dark'): boolean => HEX.test(t.colors[token][scheme]);
  for (const scheme of ['light', 'dark'] as const) {
    const pairs: [ColorToken, ColorToken, number][] = [
      ...TEXT_PAIRS.map(([a, b]): [ColorToken, ColorToken, number] => [a, b, 4.5]),
      ...MARK_PAIRS.map(([a, b]): [ColorToken, ColorToken, number] => [a, b, 3]),
    ];
    for (const [fg, bg, need] of pairs) {
      if (!valid(fg, scheme) || !valid(bg, scheme)) continue;
      const ratio = contrast(t.colors[fg][scheme], t.colors[bg][scheme]);
      if (ratio < need) {
        const lighter = scheme === 'light' ? 'Darken' : 'Lighten';
        add(`colors.${fg}.${scheme}`, `on colors.${bg}.${scheme} is ${ratio.toFixed(2)}:1; it needs ${need}:1. ${lighter} colors.${fg}.${scheme} or move colors.${bg}.${scheme} away from it.`);
      }
    }
    if (valid('accent', scheme)) {
      const ratio = contrast(WHITE, t.colors.accent[scheme]);
      if (ratio < 3) add(`colors.accent.${scheme}`, `under a white button label is ${ratio.toFixed(2)}:1; it needs 3:1. Darken colors.accent.${scheme}.`);
      // Plain buttons in a settings list (the support link) draw their label in the accent on the platform's own list background.
      const list = scheme === 'light' ? WHITE : BLACK;
      const onList = contrast(t.colors.accent[scheme], list);
      if (onList < 4.5) {
        add(`colors.accent.${scheme}`, `as link text on the platform's ${scheme} list background (${list}) is ${onList.toFixed(2)}:1; it needs 4.5:1. ${scheme === 'light' ? 'Darken' : 'Lighten'} colors.accent.${scheme}.`);
      }
    }
  }

  const ids = new Set<string>();
  t.templates.forEach((template, i) => {
    const at = `templates[${i}]`;
    if (!ID.test(template.id)) add(`${at}.id`, `"${template.id}" must be lowercase letters, digits and hyphens, starting with a letter.`);
    if (ids.has(template.id)) add(`${at}.id`, `"${template.id}" is used by an earlier template. Give each template its own id.`);
    ids.add(template.id);
    if (template.name.trim() === '') add(`${at}.name`, 'is empty. Name the template as the clinician knows it.');
    const headings = new Set<string>();
    template.sections.forEach((section, j) => {
      const field = `${at}.sections[${j}]`;
      const heading = section.heading.trim();
      if (heading === '' || heading.includes('\n') || heading.startsWith('#')) {
        add(`${field}.heading`, 'must be one line of plain text without "#". The app adds the Markdown heading.');
      }
      if (headings.has(heading.toLowerCase())) add(`${field}.heading`, `"${heading}" repeats a heading in this template. Use each heading once.`);
      headings.add(heading.toLowerCase());
      if (section.guidance.trim() === '') add(`${field}.guidance`, 'is empty. Write one sentence telling the model what belongs here.');
    });
  });
  if (!ids.has(t.defaults.template)) {
    add('defaults.template', `"${t.defaults.template}" is not a template id. Use one of: ${[...ids].join(', ')}.`);
  }

  if (t.support?.email !== undefined && !EMAIL.test(t.support.email)) add('support.email', `"${t.support.email}" is not an email address.`);
  if (t.support?.url !== undefined && !t.support.url.startsWith('https://')) add('support.url', `"${t.support.url}" must start with https://.`);
  if (!t.icon.endsWith('.png')) add('icon', `"${t.icon}" must be a PNG file.`);
  else if (!fileExists(t.icon)) add('icon', `tenants/${t.icon} does not exist. Add the PNG there or fix the path.`);

  return problems;
}
