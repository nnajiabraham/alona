#!/usr/bin/env bun
// Builds Alona's desktop apps: the Electron shell in desktop/ around the web build.
//
//   bun tools/build-desktop.mjs              Linux .deb (x64, arm64) and the Windows x64 installer
//   bun tools/build-desktop.mjs linux        only the .deb files
//   bun tools/build-desktop.mjs win          only Windows
//   bun tools/build-desktop.mjs site         only the web engine and the site in dist/desktop-site
//
// Outputs go to desktop/out/ (git-ignored), with artifacts.json listing each
// file's name, size, and SHA-256. The Windows NSIS installer needs Windows or
// Wine; where it cannot be made, a portable x64 zip is built instead and
// artifacts.json records why.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const DESKTOP = join(ROOT, 'desktop');
const OUT = join(DESKTOP, 'out');
const SITE = join(ROOT, 'dist', 'desktop-site');
const BUN = process.execPath;
const wanted = new Set(process.argv.slice(2));
const all = wanted.size === 0;

function run(command, args, cwd = ROOT) {
  console.log(`$ ${command} ${args.join(' ')}`);
  const result = spawnSync(command, args, { cwd, stdio: 'inherit' });
  return result.status === 0;
}

function must(command, args, cwd) {
  if (!run(command, args, cwd)) throw new Error(`${command} ${args.join(' ')} failed`);
}

const builder = (args) => run(join(DESKTOP, 'node_modules', '.bin', 'electron-builder'), ['--config', 'electron-builder.json', ...args], DESKTOP);

must(BUN, ['tools/build-web-engine.mjs']);
rmSync(SITE, { recursive: true, force: true });
must(BUN, ['exact.mjs', 'web-build', '--out', 'dist/desktop-site']);
for (const file of ['index.html', 'shell.html', 'modules/worker.js', 'modules/ort/ort-wasm-simd-threaded.asyncify.wasm']) {
  if (!existsSync(join(SITE, file))) throw new Error(`the web build has no ${file}`);
}
if (wanted.has('site')) process.exit(0);

must(BUN, ['install', '--frozen-lockfile'], DESKTOP);
must('node', ['node_modules/electron/install.js'], DESKTOP);
rmSync(OUT, { recursive: true, force: true });

const notes = {};
if (all || wanted.has('linux')) {
  if (!builder(['--linux', 'deb', '--x64', '--arm64'])) throw new Error('the .deb build failed');
}
if (all || wanted.has('win')) {
  if (!builder(['--win', 'nsis', '--x64'])) {
    notes.windows = 'The NSIS installer failed on this host (see the log above); built the portable zip instead. '
      + 'Build the installer on Windows: bun tools/build-desktop.mjs win';
    if (!builder(['--win', 'zip', '--x64'])) throw new Error('the Windows zip build failed too');
  }
}

const artifacts = readdirSync(OUT)
  .filter((name) => /\.(deb|exe|zip)$/.test(name))
  .map((name) => {
    const bytes = readFileSync(join(OUT, name));
    return { name, bytes: statSync(join(OUT, name)).size, sha256: createHash('sha256').update(bytes).digest('hex') };
  });
writeFileSync(join(OUT, 'artifacts.json'), `${JSON.stringify({ date: new Date().toISOString(), artifacts, notes }, null, 2)}\n`);
for (const a of artifacts) console.log(`${a.name}  ${(a.bytes / 1e6).toFixed(1)} MB  ${a.sha256}`);
for (const note of Object.values(notes)) console.log(note);
