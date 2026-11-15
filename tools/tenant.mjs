#!/usr/bin/env bun
// Builds the clinic app for one tenant. A tenant is one file, tenants/<slug>.ts,
// and its icon; tenants/README.md explains the fields.
//
//   bun tools/tenant.mjs list
//   bun tools/tenant.mjs check <slug>             type-check and validate the config
//   bun tools/tenant.mjs icon <slug>              draw a placeholder icon in the tenant's accent
//   bun tools/tenant.mjs build <slug> <web|android|ios> [exact flags…]
//   bun tools/tenant.mjs verify <slug> [web|android]
//   bun tools/tenant.mjs flows <slug> <web|web-phone|android> [flow…]
//   bun tools/tenant.mjs exact <slug> <exact verb and flags…>
//
// `build` writes a complete Exact app to .exact/tenants/<slug>/ (git-ignored):
// clinic/'s view, data module and tests, and from the config a manifest,
// a brand token file, the strings table and a typed tenant module. The app
// imports the repository's core/ and tenants/ through app.json's
// typescript.sources, and copies the engines from modules/.
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, lstatSync, realpathSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const BUN = process.execPath;
const TENANTS = join(ROOT, 'tenants');
const CLINIC = join(ROOT, 'clinic');
const NOT_TENANTS = new Set(['schema', 'validate']);

const fail = (message) => {
  console.error(message);
  process.exit(1);
};

const slugs = () =>
  readdirSync(TENANTS).filter((f) => f.endsWith('.ts') && !f.endsWith('.test.ts') && !NOT_TENANTS.has(f.slice(0, -3))).map((f) => f.slice(0, -3)).sort();

const buildDir = (slug) => join(ROOT, '.exact', 'tenants', slug);
const appDir = (slug) => join(buildDir(slug), 'app');

function known(slug) {
  if (!slug) fail(`name a tenant: ${slugs().join(', ')}`);
  if (!existsSync(join(TENANTS, `${slug}.ts`))) fail(`no tenant "${slug}": tenants/${slug}.ts does not exist. Tenants: ${slugs().join(', ')}`);
}

async function load(slug) {
  const mod = await import(join(TENANTS, `${slug}.ts`));
  if (!mod.default) fail(`tenants/${slug}.ts has no default export. End it with \`export default defineTenant({ … })\`.`);
  return mod.default;
}

// ---- check ----

function typeCheck(slug) {
  const tsc = join(ROOT, 'node_modules', '.bin', 'tsc');
  if (!existsSync(tsc)) fail('TypeScript is not installed: run `bun install` at the repository root.');
  const result = spawnSync(tsc, ['--noEmit', '--strict', '--target', 'es2022', '--module', 'esnext', '--moduleResolution', 'bundler',
    '--skipLibCheck', '--allowImportingTsExtensions', '--lib', 'es2022', join(TENANTS, `${slug}.ts`)], { cwd: ROOT, encoding: 'utf8' });
  return result.status === 0 ? [] : result.stdout.trim().split('\n').filter((l) => l.trim() !== '').map((l) => l.replaceAll(`${ROOT}/`, ''));
}

async function check(slug) {
  known(slug);
  const typeErrors = typeCheck(slug);
  if (typeErrors.length > 0) {
    console.log(`${slug}: the config does not type-check`);
    for (const line of typeErrors) console.log(`  ${line}`);
    return false;
  }
  let tenant;
  try {
    tenant = await load(slug);
  } catch (error) {
    console.log(`${slug}: ${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
  const { validateTenant } = await import(join(TENANTS, 'validate.ts'));
  const problems = validateTenant(tenant, slug, (path) => existsSync(join(TENANTS, path)));
  if (problems.length === 0) {
    console.log(`${slug}: ok · ${tenant.app.name} · ${tenant.templates.length} templates · ${tenant.app.bundleId}`);
    return true;
  }
  console.log(`${slug}: ${problems.length} problem${problems.length === 1 ? '' : 's'}`);
  for (const p of problems) console.log(`  ${p.field} ${p.message}`);
  return false;
}

// ---- icon ----

async function icon(slug) {
  known(slug);
  const tenant = await load(slug);
  const out = join(TENANTS, tenant.icon);
  mkdirSync(dirname(out), { recursive: true });
  const accent = tenant.colors.accent.light.replace('#', '0x');
  const paper = tenant.colors.raised.light.replace('#', '0x');
  const lines = [380, 470, 560, 650].map((y, i) => `drawbox=x=352:y=${y}:w=${i === 3 ? 200 : 320}:h=34:color=${accent}:t=fill`).join(',');
  const result = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', `color=c=${accent}:s=1024x1024`, '-vf',
    `drawbox=x=272:y=232:w=480:h=560:color=${paper}:t=fill,${lines}`, '-frames:v', '1', out], { encoding: 'utf8' });
  if (result.status !== 0) fail(`ffmpeg could not draw the icon: ${result.stderr.trim()}`);
  console.log(`wrote ${relative(ROOT, out)}`);
}

// ---- build ----

/** Writes a file only when its content changed, so an unchanged build stays fresh for Exact. */
function put(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  const data = typeof content === 'string' ? Buffer.from(content) : content;
  if (existsSync(path) && readFileSync(path).equals(data)) return;
  writeFileSync(path, data);
}

/** Mirrors a source tree, changing only what differs and removing what the source no longer has. */
function mirror(from, to, skip = () => false) {
  mkdirSync(to, { recursive: true });
  const want = new Set();
  for (const name of readdirSync(from)) {
    if (name === '.DS_Store' || skip(name)) continue;
    want.add(name);
    const src = join(from, name);
    const stat = statSync(src);
    if (stat.isDirectory()) mirror(src, join(to, name));
    else if (!existsSync(join(to, name)) || !readFileSync(join(to, name)).equals(readFileSync(src))) copyFileSync(src, join(to, name));
  }
  for (const name of readdirSync(to)) if (!want.has(name)) rmSync(join(to, name), { recursive: true, force: true });
}

const TOKEN_NAMES = {
  accent: 'accent', page: 'surface.page', card: 'surface.card', raised: 'surface.raised', line: 'line.soft',
  text: 'text.primary', muted: 'text.muted', progressSoft: 'progress.soft', progressInk: 'progress.ink',
  attentionSoft: 'attention.soft', attentionInk: 'attention.ink', noticeSoft: 'notice.soft', noticeInk: 'notice.ink',
};
const PAIRED = { muted: 'card', progressInk: 'progressSoft', attentionInk: 'attentionSoft', noticeInk: 'noticeSoft' };

function tamber(tenant) {
  const c = tenant.colors;
  const line = (token) => {
    const pair = PAIRED[token] ? `  pair=${TOKEN_NAMES[PAIRED[token]]}` : '';
    return `  ${TOKEN_NAMES[token]} = light-dark(${c[token].light}, ${c[token].dark})${pair}`;
  };
  return [
    `// Generated by tools/tenant.mjs from tenants/${tenant.slug}.ts. Edit the tenant file, not this one.`,
    `tamber ${tenant.slug.replaceAll('-', '')}`,
    '',
    'theme',
    `  AccentColor = light-dark(${c.accent.light}, ${c.accent.dark})`,
    ...Object.keys(TOKEN_NAMES).map(line),
    '  ink.on-fill = #ffffff  scheme=fixed',
    '',
  ].join('\n');
}

function manifest(tenant, app) {
  const sources = { core: relative(app, join(ROOT, 'core')), tenants: relative(app, TENANTS) };
  return {
    $schema: join(process.env.EXACT ?? '/Users/manlikeabro/Documents/repos/exact', 'scripts', 'app.schema.json'),
    name: tenant.app.name,
    short_name: tenant.app.shortName,
    description: tenant.app.tagline,
    id: tenant.app.bundleId,
    start_url: '/',
    display: 'standalone',
    app: { id: tenant.app.bundleId, name: tenant.app.name },
    host: { web: {}, android: { maven: ['com.alona.local:sherpa:2.0.1', 'com.alona.local:llama:b12383'] }, ios: { minimumOS: '17.0', deviceFamily: ['iphone', 'ipad'], link: ['-lc++'] } },
    icons: [{ src: 'assets/icon.png', sizes: '1024x1024', type: 'image/png', purpose: 'any' }],
    typescript: { sources },
    theme_color: tenant.colors.page.light,
    background_color: tenant.colors.page.light,
    color_scheme_dark: { background_color: tenant.colors.page.dark },
  };
}

const tenantModule = (tenant) => `// Generated by tools/tenant.mjs from tenants/${tenant.slug}.ts. Edit the tenant file, not this one.
import { defineTenant } from './tenants/schema';

export const TENANT = defineTenant(${JSON.stringify(tenant, null, 2)});
`;

/** Tests that the build shows this tenant's words, beside clinic/'s tests of behaviour. */
const brandTests = (tenant) => {
  const q = JSON.stringify;
  return `// Generated by tools/tenant.mjs from tenants/${tenant.slug}.ts.
test "the welcome is ${tenant.slug}'s"
  clock data
  expect text "welcome-title" == ${q(tenant.copy.welcomeTitle)}
  expect text "tagline" == ${q(tenant.app.tagline)}

test "home, the new note sheet and settings carry ${tenant.slug}'s name, templates and privacy statement"
  clock data
  tap "skip-download"
  clock data
  expect text "app-name" == ${q(tenant.app.name)}
  tap "new-note-button"
  clock settle
${tenant.templates.map((t) => `  expect tree has "template-${t.id}"`).join('\n')}
  tap "new-cancel"
  clock settle
  tap "open-settings"
  clock settle
  expect text "settings-privacy" == ${q(tenant.copy.privacy)}
  expect text "settings-version" == ${q(`Version ${tenant.app.version}`)}
`;
};

const strings = (tenant) => ({
  'purpose.microphone': `Records your consultations so ${tenant.app.name} can transcribe them on this device.`,
});

const WAVEFORM_TINT = 'tint="#8c3426"';

/** A color halfway between two `#rrggbb` colors. */
const blend = (a, b) => `#${[1, 3, 5].map((i) => Math.round((parseInt(a.slice(i, i + 2), 16) + parseInt(b.slice(i, i + 2), 16)) / 2).toString(16).padStart(2, '0')).join('')}`;

// The waveform's tint takes one literal and no token, so the build writes the
// tenant's attention ink there, halfway between its light and dark values to read on both.
function withWaveformTint(contract, tenant) {
  if (!contract.includes(WAVEFORM_TINT)) fail(`clinic/app.contract no longer has ${WAVEFORM_TINT} on its waveform; update tools/tenant.mjs`);
  const { light, dark } = tenant.colors.attentionInk;
  return contract.replace(WAVEFORM_TINT, `tint="${blend(light, dark)}"`);
}

/** Copies the version of Alona's Exact files and engines the clinic app runs on, and writes the tenant's own. */
async function materialize(slug) {
  known(slug);
  if (!(await check(slug))) fail(`fix tenants/${slug}.ts first`);
  const tenant = await load(slug);
  const app = appDir(slug);
  mkdirSync(app, { recursive: true });
  for (const name of ['app.ts', 'app.test.contract']) put(join(app, name), readFileSync(join(CLINIC, name)));
  put(join(app, 'app.contract'), withWaveformTint(readFileSync(join(CLINIC, 'app.contract'), 'utf8'), tenant));
  // At clinic/lib, as in the repo, so its `../../core` and `../../tenants` reach the mounted directories in both places.
  rmSync(join(app, 'lib'), { recursive: true, force: true });
  mirror(join(CLINIC, 'lib'), join(app, 'clinic', 'lib'), (name) => name.endsWith('.test.ts'));
  mirror(join(ROOT, 'ui'), join(app, 'ui'), () => false);
  if (!existsSync(join(ROOT, 'modules', 'web', 'worker.js'))) fail('the web engine is not built: run `bun tools/build-web-engine.mjs`');
  mirror(join(ROOT, 'modules'), join(app, 'modules'), (name) => name.endsWith('.xcframework'));
  for (const name of ['exact.mjs', 'bun.lock', 'gradle.lockfile', 'gradle-verification.xml']) {
    if (existsSync(join(ROOT, name))) put(join(app, name), readFileSync(join(ROOT, name)));
  }
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
  // The repository's `file:` dependencies are relative to it; the build sits elsewhere.
  const dependencies = Object.fromEntries(Object.entries(pkg.dependencies).map(([name, spec]) =>
    [name, spec.startsWith('file:') ? `file:${realpathSync(resolve(ROOT, spec.slice(5)))}` : spec]));
  put(join(app, 'package.json'), `${JSON.stringify({ name: `clinic-${slug}`, private: true, dependencies }, null, 2)}\n`);
  // The packages are the repository's; a link keeps one install for every tenant.
  const modules = join(app, 'node_modules');
  if (!existsSync(modules)) symlinkSync(join(ROOT, 'node_modules'), modules);
  for (const name of ['core', 'tenants']) {
    const link = join(app, name);
    if (existsSync(link) && lstatSync(link).isSymbolicLink()) rmSync(link);
  }
  put(join(app, 'app.json'), `${JSON.stringify(manifest(tenant, app), null, 2)}\n`);
  put(join(app, 'app.tamber'), tamber(tenant));
  put(join(app, 'tenant.ts'), tenantModule(tenant));
  put(join(app, 'brand.test.contract'), brandTests(tenant));
  put(join(app, 'strings', 'en.json'), `${JSON.stringify(strings(tenant), null, 2)}\n`);
  put(join(app, 'assets', 'icon.png'), readFileSync(join(TENANTS, tenant.icon)));
  return { tenant, app };
}

function exact(app, args, options = {}) {
  const result = spawnSync(BUN, ['exact.mjs', ...args], { cwd: app, stdio: 'inherit', ...options });
  return result.status ?? 1;
}

// ---- main ----

const [verb, slug, ...rest] = process.argv.slice(2);
const started = Date.now();
const took = () => `${((Date.now() - started) / 1000).toFixed(1)} s`;

switch (verb) {
  case 'list':
    for (const s of slugs()) {
      const t = await load(s).catch(() => null);
      console.log(t ? `${s.padEnd(20)} ${t.app.name} · ${t.copy.person.plural} · ${t.templates.map((x) => x.name).join(', ')}` : `${s.padEnd(20)} (does not load; run check)`);
    }
    break;
  case 'check':
    process.exit((await check(slug)) ? 0 : 1);
  case 'icon':
    await icon(slug);
    break;
  case 'build': {
    const [target, ...flags] = rest;
    if (!['web', 'android', 'ios'].includes(target)) fail('usage: bun tools/tenant.mjs build <slug> <web|android|ios> [exact flags…]');
    const { app } = await materialize(slug);
    console.log(`materialized ${relative(ROOT, app)} in ${took()}`);
    const args = target === 'web' ? ['web-build', '--out', join(buildDir(slug), 'dist'), ...flags] : [target, ...flags];
    const status = exact(app, args);
    console.log(`build ${slug} ${target}: ${status === 0 ? 'ok' : `exit ${status}`} in ${took()}`);
    process.exit(status);
  }
  case 'verify': {
    const { app } = await materialize(slug);
    const status = exact(app, ['verify', ...(rest.length > 0 ? rest : ['web'])]);
    process.exit(status);
  }
  case 'flows': {
    const { app } = await materialize(slug);
    const result = spawnSync(BUN, [join(ROOT, 'tools', 'clinic-flows.mjs'), slug, app, ...rest], { cwd: ROOT, stdio: 'inherit' });
    process.exit(result.status ?? 1);
  }
  case 'exact': {
    const { app } = await materialize(slug);
    process.exit(exact(app, rest));
  }
  case 'path':
    known(slug);
    console.log(appDir(slug));
    break;
  default:
    console.error('usage: bun tools/tenant.mjs <list|check|icon|build|verify|flows|exact|path> …');
    process.exit(2);
}
