// Measures what Chrome answers for the emoji SVG text probes fingerprinters
// run — SVGTextContentElement.getComputedTextLength / getExtentOfChar and
// SVGGraphicsElement.getBBox on a <text> — and prints the table that
// src/browser/emoji_metrics.zig is transcribed from.
//
//   node tools/fingerprint/dump-emoji.mjs --headed > /tmp/emoji.json
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
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

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
  '--no-first-run', '--no-default-browser-check',
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
console.log(JSON.stringify(out, null, 1));
cdp.close();
proc.kill('SIGKILL');
