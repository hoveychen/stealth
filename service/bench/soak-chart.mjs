// Draws soak.mjs samples as inline SVG line charts (one per series), for
// pasting into a report: engine RSS against time with the load/idle phases
// shaded, and engine RSS against requests done.
//
//   node soak-chart.mjs mixed.jsonl hn.jsonl ... > charts.html

import fs from 'node:fs';

const files = process.argv.slice(2);
const COLORS = ['#2563eb', '#dc2626', '#16a34a', '#9333ea', '#ea580c', '#0891b2', '#4b5563', '#ca8a04'];
const series = files.map((f, i) => {
    const rows = fs.readFileSync(f, 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((r) => r.engine?.rssKB);
    return { name: rows[0].label.replace(/^lp-crawl-c-/, ''), rows, color: COLORS[i % COLORS.length] };
});

function chart({ title, x, y, xLabel, yLabel, shade }) {
    const W = 760, H = 300, L = 56, R = 120, T = 28, B = 40;
    const xs = series.flatMap((s) => s.rows.map(x)), ys = series.flatMap((s) => s.rows.map(y));
    const xMax = Math.max(...xs) || 1, yMax = Math.max(...ys) * 1.05 || 1;
    const px = (v) => L + (v / xMax) * (W - L - R), py = (v) => H - B - (v / yMax) * (H - T - B);
    const tick = (max) => {
        const step = 10 ** Math.floor(Math.log10(max / 4));
        const s = [1, 2, 5, 10].map((m) => m * step).find((st) => max / st <= 6);
        return Array.from({ length: Math.floor(max / s) + 1 }, (_, i) => i * s);
    };
    let svg = `<svg viewBox="0 0 ${W} ${H}" width="100%" style="max-width:${W}px;font:11px sans-serif">`;
    svg += `<text x="${L}" y="16" font-weight="600" font-size="13">${title}</text>`;
    if (shade) {
        for (const s of series.slice(0, 1)) {
            let start = null;
            s.rows.forEach((r, i) => {
                const idle = r.phase.includes('idle');
                if (idle && start == null) start = x(r);
                if ((!idle || i === s.rows.length - 1) && start != null) {
                    svg += `<rect x="${px(start)}" y="${T}" width="${px(x(r)) - px(start)}" height="${H - T - B}" fill="#9ca3af" opacity="0.18"/>`;
                    start = null;
                }
            });
        }
    }
    for (const v of tick(yMax)) svg += `<line x1="${L}" x2="${W - R}" y1="${py(v)}" y2="${py(v)}" stroke="#e5e7eb"/><text x="${L - 6}" y="${py(v) + 4}" text-anchor="end">${v}</text>`;
    for (const v of tick(xMax)) svg += `<text x="${px(v)}" y="${H - B + 16}" text-anchor="middle">${v}</text>`;
    svg += `<text x="${(L + W - R) / 2}" y="${H - 6}" text-anchor="middle">${xLabel}</text><text x="12" y="${(T + H - B) / 2}" transform="rotate(-90 12 ${(T + H - B) / 2})" text-anchor="middle">${yLabel}</text>`;
    series.forEach((s, i) => {
        const pts = s.rows.map((r) => `${px(x(r)).toFixed(1)},${py(y(r)).toFixed(1)}`).join(' ');
        svg += `<polyline points="${pts}" fill="none" stroke="${s.color}" stroke-width="1.6"/>`;
        const last = s.rows.at(-1);
        svg += `<text x="${W - R + 6}" y="${T + 14 + i * 15}" fill="${s.color}">■ ${s.name}</text>`;
        void last;
    });
    return svg + '</svg>';
}

const mb = (r) => r.engine.rssKB / 1024;
console.log(chart({ title: 'engine RSS over time (grey: idle)', x: (r) => r.t / 60, y: mb, xLabel: 'minutes', yLabel: 'MB', shade: true }));
console.log(chart({ title: 'engine RSS against requests done', x: (r) => r.done / 1000, y: mb, xLabel: 'thousand requests', yLabel: 'MB' }));
