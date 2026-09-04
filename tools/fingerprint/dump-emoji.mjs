// Measures what Chrome answers for the emoji SVG text probes fingerprinters
// run — SVGTextContentElement.getComputedTextLength / getExtentOfChar and
// SVGGraphicsElement.getBBox on a <text> — and prints the table that
// src/browser/emoji_metrics.zig is transcribed from.
//
//   node tools/fingerprint/dump-emoji.mjs --headed > /tmp/emoji.json
//   node tools/fingerprint/dump-emoji.mjs --headed --zig > src/browser/emoji_metrics.zig
//
// The emoji list is CreepJS's, verbatim (creep.js `const EMOJIS`), because
// that is the set an engine is actually asked about. Everything is measured
// at two sizes so the transcription can assert the numbers are linear in
// font-size before it stores a single basis.

import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Cdp, newPage, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9481);
const HEADED = process.argv.includes('--headed');

const EMOJI_CODES = [
  [128512], [9786], [129333, 8205, 9794, 65039], [9832], [9784], [9895], [8265], [8505],
  [127987, 65039, 8205, 9895, 65039], [129394], [9785], [9760], [129489, 8205, 129456],
  [129487, 8205, 9794, 65039], [9975], [129489, 8205, 129309, 8205, 129489], [9752], [9968],
  [9961], [9972], [9992], [9201], [9928], [9730], [9969], [9731], [9732], [9976], [9823],
  [9937], [9000], [9993], [9999],
  [128105, 8205, 10084, 65039, 8205, 128139, 8205, 128104],
  [128104, 8205, 128105, 8205, 128103, 8205, 128102],
  [128104, 8205, 128105, 8205, 128102],
  [128512],
  [169], [174], [8482],
  [128065, 65039, 8205, 128488, 65039],
  [10002], [9986], [9935], [9874], [9876], [9881], [9939], [9879], [9904], [9905], [9888],
  [9762], [9763], [11014], [8599], [10145], [11013], [9883], [10017], [10013], [9766], [9654],
  [9197], [9199], [9167], [9792], [9794], [10006], [12336], [9877], [9884], [10004], [10035],
  [10055], [9724], [9642], [10083], [10084], [9996], [9757], [9997], [10052], [9878], [8618],
  [9775], [9770], [9774], [9745], [10036], [127344], [127359],
];

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'emoji-'));
const proc = spawn(CHROME, [
  ...(HEADED ? [] : ['--headless=new']),
  `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
  '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
], { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream('/tmp/dump-emoji-chrome.log');
proc.stdout.pipe(log);
proc.stderr.pipe(log);
await sleep(1800);

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { sessionId } = await newPage(cdp);
await cdp.send('Page.navigate', { url: 'about:blank' }, sessionId);
await sleep(400);

const src = `(() => {
  const CODES = ${JSON.stringify(EMOJI_CODES)};
  const emojis = CODES.map((c) => String.fromCodePoint(...c));
  const d = document;
  const host = d.createElement('div');
  host.style.cssText = 'position:absolute;left:-9999px;height:auto';
  d.body.appendChild(host);

  function measureAt(size) {
    host.innerHTML = '<style>.probe{font-family:sans-serif;font-size:' + size + 'px !important;height:auto;position:absolute !important}</style>'
      + '<svg><g id="g">' + emojis.map((e, i) => '<text id="t' + i + '" x="32" y="32" class="probe">' + e + '</text>').join('') + '</g></svg>';
    const rows = emojis.map((e, i) => {
      const el = d.getElementById('t' + i);
      const ext = el.getExtentOfChar(0);
      const bb = el.getBBox();
      return {
        codes: CODES[i],
        advance: el.getComputedTextLength(),
        ext: { x: ext.x, y: ext.y, width: ext.width, height: ext.height },
        bbox: { x: bb.x, y: bb.y, width: bb.width, height: bb.height },
      };
    });
    const g = d.getElementById('g');
    const gb = g.getBBox();
    return { size, rows, group: { x: gb.x, y: gb.y, width: gb.width, height: gb.height } };
  }

  // A latin control string, to see whether the SVG text path agrees with the
  // canvas measureText table we already ship.
  function latinAt(size) {
    host.innerHTML = '<style>.probe{font-family:sans-serif;font-size:' + size + 'px !important}</style>'
      + '<svg><text id="lat" x="0" y="0" class="probe">Hello, world!</text></svg>';
    const el = d.getElementById('lat');
    const bb = el.getBBox();
    const ext = el.getExtentOfChar(0);
    return {
      size,
      computedTextLength: el.getComputedTextLength(),
      subStringLength: el.getSubStringLength(0, 5),
      ext: { x: ext.x, y: ext.y, width: ext.width, height: ext.height },
      bbox: { x: bb.x, y: bb.y, width: bb.width, height: bb.height },
    };
  }

  const out = { at100: measureAt(100), at200: measureAt(200), latin100: latinAt(100), latin200: latinAt(200) };
  d.body.removeChild(host);
  return out;
})()`;

const out = await evaluate(cdp, sessionId, src, {});
cdp.close();
proc.kill('SIGKILL');

if (!process.argv.includes('--zig')) {
  console.log(JSON.stringify(out, null, 1));
} else {
  process.stdout.write(toZig(out));
}

function toZig(data) {
  const seen = new Set();
  const rows = [];
  let worst = 0;
  for (let i = 0; i < data.at100.rows.length; i++) {
    const a = data.at100.rows[i];
    const b = data.at200.rows[i];
    const key = a.codes.join(',');
    if (seen.has(key)) continue;
    seen.add(key);
    worst = Math.max(worst, Math.abs(a.advance * 2 - b.advance));
    rows.push(a);
  }
  // Longest first: the lookup takes the first cluster that matches, and a
  // ZWJ sequence must win over its own leading codepoint.
  const utf8Len = (r) => Buffer.byteLength(String.fromCodePoint(...r.codes), 'utf8');
  rows.sort((x, y) => utf8Len(y) - utf8Len(x) || x.codes[0] - y.codes[0]);
  const body = rows.map((r) => {
    const label = String.fromCodePoint(...r.codes);
    const escaped = r.codes.map((c) => '\\u{' + c.toString(16) + '}').join('');
    const units = [...label].reduce((n, c) => n + (c.codePointAt(0) > 0xffff ? 2 : 1), 0);
    return `    .{ .text = "${escaped}", .units = ${units}, .advance = ${r.advance} }, // ${label}`;
  }).join('\n');

  return `// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// GENERATED — do not hand-edit. Produced by
//   node tools/fingerprint/dump-emoji.mjs --headed --zig
//
// What headed Chrome on macOS advances for the emoji a fingerprinting script
// measures. The set is CreepJS's own list, because that is the one an engine
// is actually asked about: it lays all of them out as SVG <text> at 200px and
// keys its report on how many *distinct* widths come back. Chrome answers
// ${new Set(data.at200.rows.map((r) => r.advance)).size} distinct widths across these ${rows.length} clusters; a rule of thumb like
// "an emoji is one em wide" answers 1, which is the tell.
//
// Each entry is one shaped cluster — a ZWJ sequence is a single glyph with a
// single advance, not the sum of its parts — measured at 100px. Scaling that
// to another size is off by at most ${worst} px at 200px, because
// Chrome quantises the advance per size; we do not model that.
//
// Measured under \`font-family: sans-serif\`. A colour-emoji glyph is
// family-independent — it always comes from Apple Color Emoji — but a BMP
// dingbat that some text font also carries is not: Chrome makes ☺ 147.3671875
// under sans-serif and under CreepJS's own family list, and 204.203125 under
// serif. We keep one table, so serif text is charged the sans-serif width for
// those few characters.

/// One shaped cluster and its advance at the 100px basis. \`units\` is the
/// cluster's length in UTF-16 code units, which is how the DOM counts
/// characters.
pub const Cluster = struct {
    text: []const u8,
    units: u32,
    advance: f64,
};

pub const basis = 100.0;

/// Ordered longest-cluster-first so \`match\` can return the first hit.
pub const clusters = [_]Cluster{
${body}
};

/// The measured cluster \`text\` starts with, or null when we have no
/// measurement for it.
///
/// Callers ask this at every character position of every string they measure,
/// so the answer for the overwhelming majority of them -- runs of ordinary
/// text, which no cluster above begins with -- has to cost one array read
/// rather than a walk of the whole table. Charging plain text 91 prefix
/// comparisons per character is what made \`document.elementFromPoint\` take
/// 50ms a call on a retail page, and a page that calls it in an
/// IntersectionObserver handler never came back.
pub fn match(text: []const u8) ?Cluster {
    if (text.len == 0 or !starts_a_cluster[text[0]]) {
        return null;
    }
    for (clusters) |cluster| {
        if (std.mem.startsWith(u8, text, cluster.text)) {
            return cluster;
        }
    }
    return null;
}

/// Which lead bytes any cluster above starts with. Derived from the table so
/// it cannot drift out of step with it.
const starts_a_cluster = blk: {
    var table = [_]bool{false} ** 256;
    for (clusters) |cluster| {
        table[cluster.text[0]] = true;
    }
    break :blk table;
};

const std = @import("std");
`.trimEnd() + '\n';
}
