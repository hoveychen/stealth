// Third-party detector pages and the in-page extractors that scrape their
// verdicts out of the DOM. Shared by the lightpanda and Chrome collectors so
// both columns of the before/after table are produced the same way.

export const SANNYSOFT_URL = 'https://bot.sannysoft.com/';
export const CREEPJS_URL = 'https://abrahamjuliot.github.io/creepjs/';

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
