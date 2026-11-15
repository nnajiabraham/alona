#!/usr/bin/env bun
// Builds every platform's package into release/ and publishes them as a
// GitHub release.
//
//   bun tools/release.mjs build [target…]     macos android web desktop ios clinic (default: all that can build here)
//   bun tools/release.mjs notes               write release/NOTES.md and release/SHA256SUMS.txt from what is in release/
//   bun tools/release.mjs publish             create or update the GitHub release for v<version> with release/'s files
//
// The version is package.json's. Nothing here signs with a developer
// identity: the macOS app is ad-hoc signed, and the Windows installer and the
// Linux packages are unsigned. The notes say so and how to open each one.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..');
const OUT = join(ROOT, 'release');
const VERSION = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).version;
const TAG = `v${VERSION}`;
const BUN = process.execPath;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...options });
  if (result.status !== 0) {
    const reason = `${result.stderr}`.split('\n').filter((l) => l.trim() !== '' && !l.startsWith('    at ')).slice(-6).join('\n');
    throw new Error(`${command} ${args.slice(0, 4).join(' ')} exited ${result.status}\n${reason}`);
  }
  return result.stdout;
}

/** Exact's `--json` builds print one JSON object as their last stdout line. */
function exactBuild(args, env = {}) {
  const lines = run(BUN, ['exact.mjs', ...args, '--json'], { env: { ...process.env, ...env } }).trim().split('\n');
  return JSON.parse(lines.at(-1));
}

const zip = (source, name) => run('ditto', ['-c', '-k', '--keepParent', source, join(OUT, name)]);

const BUILDS = {
  macos() {
    const built = exactBuild(['mac', '--release']);
    zip(built.artifact ?? built.path, `Alona-${VERSION}-macos-arm64.zip`);
  },
  android() {
    const built = exactBuild(['android', '--release', '--no-install']);
    copyFileSync(built.artifact ?? built.path, join(OUT, `Alona-${VERSION}-android-arm64.apk`));
  },
  ios() {
    // Exact's iOS host needs Xcode 27.1 or later. Where the selected Xcode is older, name the newer one.
    const xcode27 = '/Applications/Xcode-27.app/Contents/Developer';
    const built = exactBuild(['ios', '--release'], !process.env.DEVELOPER_DIR && existsSync(xcode27) ? { DEVELOPER_DIR: xcode27 } : {});
    zip(built.artifact ?? built.path, `Alona-${VERSION}-ios-simulator.zip`);
  },
  web() {
    run(BUN, ['tools/build-web-engine.mjs']);
    const site = join(tmpdir(), `alona-web-${Date.now()}`, `Alona-${VERSION}-web`);
    mkdirSync(dirname(site), { recursive: true });
    run(BUN, ['exact.mjs', 'web-build', '--out', site]);
    zip(site, `Alona-${VERSION}-web.zip`);
    rmSync(dirname(site), { recursive: true, force: true });
  },
  desktop() {
    run(BUN, ['tools/build-desktop.mjs']);
    const built = join(ROOT, 'desktop', 'out');
    for (const name of readdirSync(built).filter((n) => n.endsWith('.deb') || n.endsWith('.exe'))) {
      copyFileSync(join(built, name), join(OUT, name));
    }
  },
  /** The clinical app, once per tenant file: a web build and an Android package. */
  clinic() {
    const tenants = readdirSync(join(ROOT, 'tenants')).filter((n) => n.endsWith('.ts') && !['schema.ts', 'validate.ts'].includes(n) && !n.endsWith('.test.ts')).map((n) => n.slice(0, -3)).sort();
    for (const slug of tenants) {
      const dir = join(ROOT, '.exact', 'tenants', slug);
      run(BUN, ['tools/tenant.mjs', 'build', slug, 'web']);
      const site = join(tmpdir(), `clinic-web-${Date.now()}`, `Clinic-${slug}-${VERSION}-web`);
      mkdirSync(dirname(site), { recursive: true });
      run('ditto', [join(dir, 'dist'), site]);
      zip(site, `Clinic-${slug}-${VERSION}-web.zip`);
      rmSync(dirname(site), { recursive: true, force: true });
      run(BUN, ['tools/tenant.mjs', 'build', slug, 'android', '--release', '--no-install']);
      copyFileSync(join(dir, 'app', 'target', 'android', 'app', 'outputs', 'apk', 'release', 'app-release.apk'), join(OUT, `Clinic-${slug}-${VERSION}-android-arm64.apk`));
    }
  },
};

const sha256 = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const packages = () => readdirSync(OUT).filter((n) => !n.endsWith('.md') && !n.endsWith('.txt')).sort();
const megabytes = (path) => `${(statSync(path).size / 1e6).toFixed(1)} MB`;

const HOW = [
  [/^Clinic-.*-web\.zip$/, 'Clinical app, web', 'One tenant\'s build of the clinical app. Unzip and serve the folder as for Alona\'s web build.'],
  [/^Clinic-.*\.apk$/, 'Clinical app, Android (arm64)', 'One tenant\'s build of the clinical app. Install with `adb install`.'],
  [/macos-arm64\.zip$/, 'macOS (Apple silicon)', 'Unzip and move Alona.app to Applications. It is not signed with a developer identity, so the first time, right-click it and choose Open, or run `xattr -dr com.apple.quarantine /Applications/Alona.app`.'],
  [/android-arm64\.apk$/, 'Android (arm64)', 'Install with `adb install` or open the file on the phone after allowing installs from this source.'],
  [/ios-simulator\.zip$/, 'iOS Simulator', 'Unzip, then `xcrun simctl install booted Alona.app`. This build runs in the Simulator only. A build for a phone needs a signing identity and a provisioning profile.'],
  [/-web\.zip$/, 'Web', 'Unzip and serve the folder over https or from localhost with any static server that falls back to shell.html for unknown paths. The app needs WebGPU to run its models.'],
  [/_amd64\.deb$/, 'Linux x64', '`sudo apt install ./<file>`. Unsigned. Needs a GPU with Vulkan for real models; without one the app shows samples and says so.'],
  [/_arm64\.deb$/, 'Linux arm64', '`sudo apt install ./<file>`. Unsigned.'],
  [/\.exe$/, 'Windows x64', 'Run the installer. It is unsigned, so SmartScreen warns: choose More info, then Run anyway.'],
];

function notes() {
  const rows = packages().map((name) => {
    const how = HOW.find(([pattern]) => pattern.test(name));
    return `| \`${name}\` | ${how?.[1] ?? ''} | ${megabytes(join(OUT, name))} | ${how?.[2] ?? ''} |`;
  });
  const extra = existsSync(join(ROOT, 'docs', 'release-notes.md')) ? readFileSync(join(ROOT, 'docs', 'release-notes.md'), 'utf8').trim() : '';
  writeFileSync(join(OUT, 'NOTES.md'), `${extra}\n\n## Packages\n\n| File | Platform | Size | How to install |\n|---|---|---|---|\n${rows.join('\n')}\n\nSHA-256 checksums are in \`SHA256SUMS.txt\`.\n`);
  writeFileSync(join(OUT, 'SHA256SUMS.txt'), `${packages().map((name) => `${sha256(join(OUT, name))}  ${name}`).join('\n')}\n`);
  console.log(`notes for ${packages().length} packages`);
}

function publish() {
  notes();
  const files = [...packages(), 'SHA256SUMS.txt'].map((name) => join(OUT, name));
  const head = run('git', ['rev-parse', 'HEAD']).trim();
  const exists = spawnSync('gh', ['release', 'view', TAG], { cwd: ROOT }).status === 0;
  if (exists) {
    run('gh', ['release', 'upload', TAG, ...files, '--clobber']);
    run('gh', ['release', 'edit', TAG, '--notes-file', join(OUT, 'NOTES.md')]);
  } else {
    run('gh', ['release', 'create', TAG, ...files, '--target', head, '--title', `Alona ${VERSION}`, '--notes-file', join(OUT, 'NOTES.md'), '--prerelease']);
  }
  console.log(run('gh', ['release', 'view', TAG, '--json', 'url', '--jq', '.url']).trim());
}

const [verb, ...targets] = process.argv.slice(2);
mkdirSync(OUT, { recursive: true });
if (verb === 'build') {
  const names = targets.length > 0 ? targets : Object.keys(BUILDS);
  let failed = 0;
  for (const name of names) {
    if (!BUILDS[name]) throw new Error(`no such target: ${name}. Targets: ${Object.keys(BUILDS).join(', ')}`);
    try {
      BUILDS[name]();
      console.log(`${name}: built`);
    } catch (error) {
      failed += 1;
      console.log(`${name}: FAILED\n  ${error.message.split('\n').join('\n  ')}`);
    }
  }
  for (const name of packages()) console.log(`  ${basename(name)}  ${megabytes(join(OUT, name))}`);
  process.exit(failed === 0 ? 0 : 1);
} else if (verb === 'notes') {
  notes();
} else if (verb === 'publish') {
  publish();
} else {
  console.error('usage: bun tools/release.mjs build [macos android ios web desktop clinic] | notes | publish');
  process.exit(2);
}
