// Alona's desktop shell: one window around the web build, which
// tools/build-desktop.mjs writes to dist/desktop-site and packages as ./site.
//
// The site is served from alona://app, a standard and secure scheme, so
// IndexedDB, the Cache API, module Workers, and WebGPU behave as on https.
// Every response carries COOP and COEP, which makes the page cross-origin
// isolated: SharedArrayBuffer and threaded WASM are then available, and the
// web engine spike measured those paths 2.7 to 3.8 times faster.
import { app, BrowserWindow, Menu, protocol, session, shell } from 'electron';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';

const SCHEME = 'alona';
const ORIGIN = `${SCHEME}://app`;
const SITE = app.isPackaged ? join(app.getAppPath(), 'site') : join(app.getAppPath(), '..', 'dist', 'desktop-site');

const ISOLATION = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
};

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.plan': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.woff2': 'font/woff2',
};

// The page itself downloads the pinned model files from Hugging Face, which
// redirects large files to its *.hf.co storage. Nothing else may leave.
const ALLOWED_HOSTS = [/^huggingface\.co$/, /\.hf\.co$/];

if (process.platform === 'linux') {
  // Chromium on Linux ships WebGPU off; it runs on Vulkan once enabled.
  app.commandLine.appendSwitch('enable-unsafe-webgpu');
  app.commandLine.appendSwitch('enable-features', 'Vulkan');
}

app.setName('Alona');

protocol.registerSchemesAsPrivileged([{
  scheme: SCHEME,
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true, codeCache: true },
}]);

async function fileAt(pathname) {
  const path = normalize(join(SITE, decodeURIComponent(pathname)));
  if (path !== SITE && !path.startsWith(SITE + sep)) return null;
  try {
    return (await stat(path)).isFile() ? path : null;
  } catch {
    return null;
  }
}

/** Exact's static-host rule: the file at the path, else the shell page for an app route, else 404. */
async function serve(request) {
  const { pathname } = new URL(request.url);
  let path = await fileAt(pathname === '/' ? '/index.html' : pathname);
  let status = 200;
  if (!path) {
    path = join(SITE, 'shell.html');
    if (extname(pathname) !== '') status = 404;
  }
  const type = TYPES[extname(path)] ?? 'application/octet-stream';
  return new Response(await readFile(path), { status, headers: { 'Content-Type': type, ...ISOLATION } });
}

function allowedRequest(url) {
  const { protocol: scheme, hostname } = new URL(url);
  if (['http:', 'ws:', 'wss:', 'ftp:'].includes(scheme)) return false;
  if (scheme !== 'https:') return true;
  return ALLOWED_HOSTS.some((host) => host.test(hostname));
}

function lockDown(ses) {
  ses.protocol.handle(SCHEME, serve);
  ses.setPermissionRequestHandler((contents, permission, callback, details) => {
    const granted = permission === 'media'
      && isApp(details.requestingUrl)
      && (details.mediaTypes ?? []).every((type) => type === 'audio');
    if (!granted) console.log(`[alona] denied permission ${permission} ${JSON.stringify(details.mediaTypes ?? [])} for ${details.requestingUrl}`);
    callback(granted);
  });
  ses.setPermissionCheckHandler((contents, permission, origin, details) =>
    permission === 'media' && isApp(origin) && details.mediaType !== 'video');
  ses.webRequest.onBeforeRequest({ urls: ['<all_urls>'] }, (details, callback) => {
    const allowed = allowedRequest(details.url);
    if (!allowed) console.log(`[alona] blocked request ${details.url}`);
    callback({ cancel: !allowed });
  });
  ses.setSpellCheckerEnabled(false);
}

// Node's URL reports the origin of a non-special scheme such as alona: as "null".
function isApp(url) {
  try {
    const parsed = new URL(url);
    return `${parsed.protocol}//${parsed.host}` === ORIGIN;
  } catch {
    return false;
  }
}

function openOutside(url) {
  if (/^https?:\/\//.test(url)) shell.openExternal(url);
}

function createWindow() {
  const window = new BrowserWindow({
    title: 'Alona',
    width: 1040,
    height: 760,
    minWidth: 420,
    minHeight: 560,
    show: false,
    icon: join(app.getAppPath(), 'resources', 'icon.png'),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      webviewTag: false,
    },
  });
  window.once('ready-to-show', () => window.show());
  window.loadURL(`${ORIGIN}/`);
  return window;
}

app.on('web-contents-created', (event, contents) => {
  contents.on('will-navigate', (navigation) => {
    if (isApp(navigation.url)) return;
    navigation.preventDefault();
    openOutside(navigation.url);
  });
  contents.on('will-redirect', (navigation) => {
    if (navigation.isMainFrame && !isApp(navigation.url)) navigation.preventDefault();
  });
  contents.setWindowOpenHandler(({ url }) => {
    openOutside(url);
    return { action: 'deny' };
  });
  contents.on('will-attach-webview', (attach) => attach.preventDefault());
});

const menu = [
  ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : [{ role: 'fileMenu' }]),
  { role: 'editMenu' },
  {
    label: 'View',
    submenu: [{ role: 'reload' }, { type: 'separator' }, { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
      { type: 'separator' }, { role: 'togglefullscreen' }],
  },
  { role: 'windowMenu' },
];

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let main = null;
  app.on('second-instance', () => {
    if (!main) return;
    if (main.isMinimized()) main.restore();
    main.focus();
  });
  app.whenReady().then(() => {
    Menu.setApplicationMenu(Menu.buildFromTemplate(menu));
    lockDown(session.defaultSession);
    main = createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) main = createWindow();
    });
  });
  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
