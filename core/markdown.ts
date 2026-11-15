/**
 * The notes pad's formatting toolbar, as edits of the Markdown source. Exact's `format` runs in
 * the web, macOS and iOS editors; Android's editor edits the source as plain text, so the pad
 * asks these functions instead. They take and give the selection in UTF-16 offsets, as a text
 * field's `InputEvent` reports it, and use the command names and the `formats` words of Exact's
 * `format` and `MarkdownSelection`.
 */

/** A source and the selection to restore in it. */
export interface PadEdit {
  value: string;
  start: number;
  end: number;
}

/** What the toolbar shows at a selection: `MarkdownSelection`'s `formats`, `link` and `unavailable`. */
export interface PadFormats {
  formats: string;
  link: string;
  unavailable: string;
}

type Inline = 'bold' | 'italic' | 'strike';
type Block = 'bullet' | 'ordered' | 'task' | 'quote';

/** An inline span: its opening marker `[open, from)`, its text `[from, to)`, its closing marker `[to, close)`. */
interface Span {
  kind: Inline | 'link';
  open: number;
  from: number;
  to: number;
  close: number;
  url: string;
}

/** A line's Markdown prefix: optional quote, then a heading or a list marker. */
interface Line {
  start: number;
  end: number;
  quote: string;
  heading: number;
  list: '' | 'bullet' | 'ordered' | 'task';
  /** The prefix text after the quote: `## `, `- `, `1. `, `- [ ] ` or `""`. */
  marker: string;
}

const clamp = (n: number, max: number) => Math.min(Math.max(0, Math.trunc(Number.isFinite(n) ? n : 0)), max);

function lineAt(source: string, at: number): Line {
  const start = source.lastIndexOf('\n', at - 1) + 1;
  const nl = source.indexOf('\n', at);
  const end = nl < 0 ? source.length : nl;
  const text = source.slice(start, end);
  const quote = /^> ?/.exec(text)?.[0] ?? '';
  const rest = text.slice(quote.length);
  const heading = /^(#{1,6}) /.exec(rest);
  const task = /^[-*+] \[[ xX]\] /.exec(rest);
  const bullet = /^[-*+] /.exec(rest);
  const ordered = /^\d{1,9}[.)] /.exec(rest);
  if (heading) return { start, end, quote, heading: heading[1].length, list: '', marker: heading[0] };
  if (task) return { start, end, quote, heading: 0, list: 'task', marker: task[0] };
  if (bullet) return { start, end, quote, heading: 0, list: 'bullet', marker: bullet[0] };
  if (ordered) return { start, end, quote, heading: 0, list: 'ordered', marker: ordered[0] };
  return { start, end, quote, heading: 0, list: '', marker: '' };
}

/** Every line the selection touches, first to last. */
function linesIn(source: string, start: number, end: number): Line[] {
  const lines = [lineAt(source, start)];
  while (lines[lines.length - 1].end < end) lines.push(lineAt(source, lines[lines.length - 1].end + 1));
  return lines;
}

/**
 * The emphasis, strikethrough and link spans of one line, by CommonMark's delimiter-run rule
 * (without its rule of three): a `*` run opens before non-space and closes after it, a closer
 * takes the nearest opener, and two of each run's markers make bold, one italic. A link's
 * destination holds no emphasis.
 */
function spansOf(source: string, line: { start: number; end: number }): Span[] {
  const spans: Span[] = [];
  const text = source.slice(line.start, line.end);
  const opaque: Array<[number, number]> = [];
  for (const m of text.matchAll(/\[([^\]\n]*)\]\(([^)\s]*)\)/g)) {
    const at = line.start + (m.index ?? 0);
    const from = at + 1;
    const to = from + m[1].length;
    spans.push({ kind: 'link', open: at, from, to, close: at + m[0].length, url: m[2] });
    opaque.push([to, at + m[0].length]);
  }
  interface Run { char: string; pos: number; len: number; left: number; canOpen: boolean; canClose: boolean }
  const runs: Run[] = [];
  for (const m of text.matchAll(/\*+|~~/g)) {
    const pos = line.start + (m.index ?? 0);
    if (opaque.some(([a, b]) => pos >= a && pos < b)) continue;
    const before = source[pos - 1] ?? ' ';
    const after = pos + m[0].length < line.end ? source[pos + m[0].length] : ' ';
    runs.push({ char: m[0][0], pos, len: m[0].length, left: m[0].length, canOpen: !/\s/.test(after), canClose: !/\s/.test(before) });
  }
  const openers: Run[] = [];
  for (const run of runs) {
    while (run.canClose && run.left > 0) {
      const i = openers.findLastIndex((o) => o.char === run.char && o.left > 0);
      if (i < 0) break;
      const opener = openers[i];
      const use = run.char === '~' ? 2 : opener.left >= 2 && run.left >= 2 ? 2 : 1;
      const from = opener.pos + opener.left;
      const to = run.pos + (run.len - run.left);
      const kind: Inline = run.char === '~' ? 'strike' : use === 2 ? 'bold' : 'italic';
      spans.push({ kind, open: from - use, from, to, close: to + use, url: '' });
      opener.left -= use;
      run.left -= use;
      openers.splice(i + 1);
      if (opener.left === 0) openers.splice(i, 1);
    }
    if (run.canOpen && run.left > 0) openers.push(run);
  }
  return spans;
}

/** The spans that hold the selection: a caret from just inside the opening marker to past the closing one, a range within the span. */
function spansAt(source: string, start: number, end: number): Span[] {
  const line = lineAt(source, start);
  if (end > line.end) return [];
  return spansOf(source, line).filter((s) =>
    start === end ? s.from <= start && start <= s.close : s.open <= start && end <= s.close && start < s.to && end > s.from,
  );
}

/** What the toolbar shows as on at the selection. */
export function formatsAt(source: string, start: number, end: number): PadFormats {
  const a = clamp(Math.min(start, end), source.length);
  const b = clamp(Math.max(start, end), source.length);
  const words: string[] = [];
  const spans = spansAt(source, a, b);
  for (const kind of ['bold', 'italic', 'strike'] as const) if (spans.some((s) => s.kind === kind)) words.push(kind);
  const link = spans.find((s) => s.kind === 'link')?.url ?? '';
  const lines = linesIn(source, a, b);
  const all = (f: (l: Line) => boolean) => lines.every(f);
  const heading = lines[0].heading;
  if (heading > 0 && all((l) => l.heading === heading)) words.push(`heading${heading}`);
  for (const list of ['bullet', 'ordered', 'task'] as const) if (all((l) => l.list === list)) words.push(list);
  if (all((l) => l.quote !== '')) words.push('quote');
  return { formats: words.join(' '), link, unavailable: '' };
}

/**
 * Replaces `[from, to)` with `text`, moving an offset as the text around it moves. A line's
 * prefix is `after`: an offset at or inside it goes past the new prefix, so the caret stays on
 * the line's text.
 */
function splice(e: PadEdit, from: number, to: number, text: string, after = false): PadEdit {
  const delta = text.length - (to - from);
  const move = after
    ? (n: number) => (n < from ? n : n >= to ? n + delta : from + text.length)
    : (n: number) => (n <= from ? n : n >= to ? n + delta : from + Math.min(n - from, text.length));
  return { value: e.value.slice(0, from) + text + e.value.slice(to), start: move(e.start), end: move(e.end) };
}

function toggleInline(e: PadEdit, kind: Inline): PadEdit {
  const marker = kind === 'bold' ? '**' : kind === 'italic' ? '*' : '~~';
  const span = spansAt(e.value, e.start, e.end).find((s) => s.kind === kind);
  if (span) {
    const unclosed = splice(e, span.to, span.close, '');
    return splice(unclosed, span.open, span.from, '');
  }
  const wrapped = splice(e, e.end, e.end, marker);
  return { ...splice(wrapped, e.start, e.start, marker), start: e.start + marker.length, end: e.end + marker.length };
}

function link(e: PadEdit, url: string): PadEdit {
  const span = spansAt(e.value, e.start, e.end).find((s) => s.kind === 'link');
  if (span && url === '') return splice(splice(e, span.to, span.close, ''), span.open, span.from, '');
  if (span) return splice(e, span.to + 2, span.close - 1, url);
  if (url === '') return e;
  const text = e.start === e.end ? url : e.value.slice(e.start, e.end);
  const linked = splice(e, e.start, e.end, `[${text}](${url})`);
  return { ...linked, start: e.start + 1, end: e.start + 1 + text.length };
}

/** Sets each selected line's prefix after its quote: `next(line, i)` gives the new prefix. */
function relines(e: PadEdit, next: (l: Line, i: number) => string): PadEdit {
  const lines = linesIn(e.value, e.start, e.end);
  let out = e;
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i];
    const at = l.start + l.quote.length;
    out = splice(out, at, at + l.marker.length, next(l, i), true);
  }
  return out;
}

function toggleBlock(e: PadEdit, kind: Block): PadEdit {
  const lines = linesIn(e.value, e.start, e.end);
  if (kind === 'quote') {
    const on = lines.every((l) => l.quote !== '');
    let out = e;
    for (const l of [...lines].reverse()) out = splice(out, l.start, l.start + (on ? l.quote.length : 0), on ? '' : '> ', true);
    return out;
  }
  const on = lines.every((l) => l.list === kind);
  const marker = (i: number) => (kind === 'bullet' ? '- ' : kind === 'task' ? '- [ ] ' : `${i + 1}. `);
  return relines(e, (_, i) => (on ? '' : marker(i)));
}

function heading(e: PadEdit, level: number): PadEdit {
  if (!Number.isInteger(level) || level < 1 || level > 6) return e;
  const on = linesIn(e.value, e.start, e.end).every((l) => l.heading === level);
  return relines(e, () => (on ? '' : `${'#'.repeat(level)} `));
}

/** A line with no heading, list or quote. */
function plain(e: PadEdit): PadEdit {
  let out = relines(e, () => '');
  for (const l of linesIn(out.value, out.start, out.end).reverse()) out = splice(out, l.start, l.start + l.quote.length, '', true);
  return out;
}

/**
 * One toolbar command on the source at `[start, end)`: the new source and the selection to
 * restore. Repeating a command where it is on takes it off. `plain` clears the lines' heading,
 * list and quote; `insert` puts `argument` in place of the selection, the caret after it. An
 * unknown command changes nothing.
 */
export function applyFormat(source: string, start: number, end: number, command: string, argument = ''): PadEdit {
  const a = clamp(Math.min(start, end), source.length);
  const b = clamp(Math.max(start, end), source.length);
  const e: PadEdit = { value: source, start: a, end: b };
  switch (command) {
    case 'bold':
    case 'italic':
    case 'strike':
      return toggleInline(e, command);
    case 'bullet':
    case 'ordered':
    case 'task':
    case 'quote':
      return toggleBlock(e, command);
    case 'heading':
      return heading(e, Number(argument));
    case 'plain':
      return plain(e);
    case 'link':
      return link(e, argument.trim());
    case 'insert': {
      const inserted = splice(e, a, b, argument);
      return { ...inserted, start: a + argument.length, end: a + argument.length };
    }
    default:
      return e;
  }
}
