import { describe, expect, test } from 'bun:test';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { defineTenant, type TenantConfig } from './schema';
import { contrast, validateTenant } from './validate';
import base from './default';

const DIR = import.meta.dir;
const exists = (path: string): boolean => existsSync(join(DIR, path));
const problems = (t: TenantConfig, slug = t.slug) => validateTenant(t, slug, exists);
const fields = (t: TenantConfig, slug?: string): string[] => problems(t, slug).map((p) => p.field);
const variant = (change: (t: TenantConfig) => TenantConfig): TenantConfig => change(structuredClone(base));

describe('the shipped tenants', () => {
  const slugs = readdirSync(DIR).filter((f) => f.endsWith('.ts') && !/^(schema|validate)\.ts$|\.test\.ts$/.test(f)).map((f) => f.slice(0, -3));

  test('there are at least three, and every one passes every rule', async () => {
    expect(slugs.length).toBeGreaterThanOrEqual(3);
    for (const slug of slugs) {
      const t: TenantConfig = (await import(`./${slug}.ts`)).default;
      expect({ slug, problems: problems(t, slug) }).toEqual({ slug, problems: [] });
    }
  });
});

describe('each rule the validator adds to the types', () => {
  test('contrast is measured as WCAG 2 defines it', () => {
    expect(contrast('#000000', '#ffffff')).toBeCloseTo(21, 5);
    expect(contrast('#777777', '#ffffff')).toBeCloseTo(4.48, 2);
  });

  test('a slug that differs from the file name', () => {
    expect(fields(base, 'other')).toEqual(['slug']);
  });

  test('a malformed slug is refused when the tenant is defined', () => {
    expect(() => defineTenant({ ...base, slug: 'Bad Slug' })).toThrow('lowercase letters');
  });

  test('two templates with one id', () => {
    const t = variant((t) => ({ ...t, templates: [t.templates[0], { ...t.templates[1], id: t.templates[0].id }] }));
    const p = problems(t);
    expect(p.map((x) => x.field)).toEqual(['templates[1].id']);
    expect(p[0].message).toContain('Give each template its own id');
  });

  test('a default template no template has', () => {
    const t = variant((t) => ({ ...t, defaults: { ...t.defaults, template: 'missing' } }));
    expect(problems(t)).toEqual([{ field: 'defaults.template', message: '"missing" is not a template id. Use one of: soap, consultation.' }]);
  });

  test('muted text too faint on its card, in the dark scheme only', () => {
    const t = variant((t) => ({ ...t, colors: { ...t.colors, muted: { ...t.colors.muted, dark: '#55605e' } } }));
    const p = problems(t);
    expect(p.map((x) => x.field)).toEqual(['colors.muted.dark', 'colors.muted.dark', 'colors.muted.dark']);
    expect(p[1].message).toMatch(/^on colors\.card\.dark is \d\.\d\d:1; it needs 4\.5:1\. Lighten colors\.muted\.dark/);
  });

  test('an accent too pale for a white button label', () => {
    const t = variant((t) => ({ ...t, colors: { ...t.colors, accent: { light: '#8fd6cf', dark: t.colors.accent.dark } } }));
    expect(problems(t).find((x) => x.message.includes('white button label'))?.field).toBe('colors.accent.light');
  });

  test('an accent too dim to read as link text in a dark settings list', () => {
    const t = variant((t) => ({ ...t, colors: { ...t.colors, accent: { light: t.colors.accent.light, dark: '#7a5cc4' } } }));
    expect(problems(t).find((x) => x.message.includes('link text'))?.field).toBe('colors.accent.dark');
  });

  test('a welcome title with a word too long for a phone at the largest text size', () => {
    const t = variant((t) => ({ ...t, copy: { ...t.copy, welcomeTitle: 'Welcome to Quillmoor' } }));
    expect(fields(t)).toEqual(['copy.welcomeTitle']);
    expect(problems(t)[0].message).toContain('"Quillmoor"');
  });

  test('a colour that is not six hex digits', () => {
    const t = variant((t) => ({ ...t, colors: { ...t.colors, line: { light: '#abc', dark: t.colors.line.dark } } }));
    expect(fields(t)).toEqual(['colors.line.light']);
  });

  test('a bundle id that is not reverse DNS', () => {
    for (const bundleId of ['clinic.notes', 'Com.Example.App', 'com.example.my-app'] as const) {
      const t = variant((t) => ({ ...t, app: { ...t.app, bundleId: bundleId as TenantConfig['app']['bundleId'] } }));
      expect(fields(t)).toEqual(['app.bundleId']);
    }
  });

  test('an icon file that does not exist, or is not a PNG', () => {
    expect(fields(variant((t) => ({ ...t, icon: 'icons/nobody.png' })))).toEqual(['icon']);
    expect(fields(variant((t) => ({ ...t, icon: 'icons/default.svg' })))).toEqual(['icon']);
  });

  test('a privacy statement that claims a regulation', () => {
    const t = variant((t) => ({ ...t, copy: { ...t.copy, privacy: 'Fully HIPAA compliant.' } }));
    expect(fields(t)).toEqual(['copy.privacy']);
  });

  test('a repeated heading, a heading with Markdown, and empty guidance', () => {
    const t = variant((t) => ({
      ...t,
      templates: [{ ...t.templates[0], sections: [
        { heading: 'Plan', guidance: 'a' }, { heading: '## Plan', guidance: 'b' }, { heading: 'plan', guidance: ' ' },
      ] }, t.templates[1]],
    }));
    expect(fields(t)).toEqual(['templates[0].sections[1].heading', 'templates[0].sections[2].heading', 'templates[0].sections[2].guidance']);
  });

  test('a short name too long for a home screen, and a capitalized noun', () => {
    const t = variant((t) => ({ ...t, app: { ...t.app, shortName: 'Clinic Notes Pro' }, copy: { ...t.copy, person: { singular: 'Patient', plural: 'patients' } } }));
    expect(fields(t)).toEqual(['app.shortName', 'copy.person.singular']);
  });

  test('support details in the wrong form', () => {
    const t = variant((t) => ({ ...t, support: { email: 'help', url: 'http://example.org' } }));
    expect(fields(t)).toEqual(['support.email', 'support.url']);
  });
});
