// Third-party detector pages and the in-page extractors that scrape their
// verdicts out of the DOM. Shared by the lightpanda and Chrome collectors so
// both columns of the before/after table are produced the same way.

export const SANNYSOFT_URL = 'https://bot.sannysoft.com/';
export const CREEPJS_URL = 'https://abrahamjuliot.github.io/creepjs/';

// The wider sweep (detector-sweep.mjs). Two of these are dead endpoints that
// answer 37 characters in every browser; they stay on the list so a future run
// notices if they come back rather than silently measuring nine sites and
// reporting twelve. Settle times are what Chrome needs plus headroom.
export const DETECTORS = [
    { name: 'sannysoft', url: SANNYSOFT_URL, settleMs: 6000 },
    { name: 'creepjs', url: CREEPJS_URL, settleMs: 22000 },
    { name: 'areyouheadless', url: 'https://arh.antoinevastel.com/bots/areyouheadless', settleMs: 8000 },
    { name: 'fpscanner', url: 'https://arh.antoinevastel.com/bots/', settleMs: 8000 },
    { name: 'rebrowser', url: 'https://bot-detector.rebrowser.net/', settleMs: 12000 },
    { name: 'deviceinfo', url: 'https://deviceandbrowserinfo.com/are_you_a_bot', settleMs: 12000 },
    { name: 'browserleaks-js', url: 'https://browserleaks.com/javascript', settleMs: 10000 },
    { name: 'browserleaks-tls', url: 'https://tls.browserleaks.com/json', settleMs: 8000 },
    { name: 'amiunique', url: 'https://amiunique.org/fingerprint', settleMs: 15000 },
    { name: 'iphey', url: 'https://iphey.com/', settleMs: 15000 },
    { name: 'pixelscan', url: 'https://pixelscan.net/', settleMs: 18000 },
    { name: 'browserscan', url: 'https://www.browserscan.net/', settleMs: 18000 },
];

// Words a detector uses to say what it decided. Counted, not interpreted: the
// question this sweep answers is "did the page finish and reach a verdict",
// not "what score did we get" — per-site scrapers rot, and a page that never
// returns a fingerprint is a louder signal than a slightly wrong one.
export const VERDICT_WORDS =
    /\b(bot|headless|automation|automated|webdriver|puppeteer|selenium|human|trustworthy|suspicious|detected|not a robot|robot)\b/gi;

// Coarse, engine-agnostic "how far did this page get" reading.
export const extractReach = `(() => {
  const text = (document.body && document.body.innerText) || '';
  return {
    title: document.title,
    href: location.href,
    ready: document.readyState,
    nodes: document.getElementsByTagName('*').length,
    textLength: text.length,
    text: text.slice(0, 4000),
    // Recorded per site, not once per run: a responsive layout deals a
    // different number of cards at a different width, so a node count is only
    // comparable against another count taken at the same width. A baseline
    // that does not carry its own viewport is how G7's pixelscan "+184
    // elements" turned out to be a window that happened to be 1200 wide.
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    dpr: window.devicePixelRatio,
  };
})()`;

// bot.sannysoft.com renders every check as a <tr> of <th>name</th><td>value</td>
// where the <td> carries a passed/failed/warn class.
export const extractSannysoft = `(() => {
  const rows = [];
  for (const tr of document.querySelectorAll('tr')) {
    const cells = tr.querySelectorAll('th, td');
    if (cells.length < 2) continue;
    const name = (cells[0].textContent || '').trim();
    const cell = cells[1];
    if (!name) continue;
    rows.push({
      name,
      value: (cell.textContent || '').trim().slice(0, 200),
      status: cell.className || cell.getAttribute('class') || '',
      id: cell.id || '',
    });
  }
  return { title: document.title, rowCount: rows.length, rows };
})()`;

// CreepJS is heavy and async. Its DOM is a flat list of "label:" lines followed
// by their values, so line-oriented regexes grab the wrong line; instead we key
// off the label and read the *next* non-empty line, and always keep the full
// text so P7 can diff before/after by hand.
export const extractCreepJs = `(() => {
  const text = (document.body && document.body.innerText) || '';
  const lines = text.split('\\n').map((l) => l.trim());
  // Value that follows a given label line (CreepJS renders "label:" then value).
  const after = (label) => {
    const i = lines.findIndex((l) => l.toLowerCase() === label.toLowerCase());
    if (i === -1) return null;
    for (let j = i + 1; j < lines.length && j < i + 3; j++) if (lines[j]) return lines[j].slice(0, 200);
    return null;
  };
  const inline = (re) => { const m = text.match(re); return m ? m[1].trim() : null; };
  const fpId = inline(/FP ID:\\s*([^\\n]+)/i);
  return {
    title: document.title,
    // "Computing..." means CreepJS never finished on this engine.
    computed: !!fpId && !/computing/i.test(fpId),
    fpId,
    fuzzy: inline(/Fuzzy:\\s*([0-9a-f]+)/i),
    likeHeadless: inline(/([0-9]+%)\\s*like headless/i),
    headlessPct: inline(/([0-9]+%)\\s*headless/i),
    stealthPct: inline(/([0-9]+%)\\s*stealth/i),
    chromium: after('chromium:'),
    platformHints: after('platform hints:'),
    lies: inline(/lies\\s*\\(([0-9]+)\\)/i),
    textLength: text.length,
    text: text.slice(0, 20000),
  };
})()`;
