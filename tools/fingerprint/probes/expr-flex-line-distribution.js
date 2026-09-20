// What a flex line does with the space its items did not take: the `gap`
// between them, the `justify-content` that distributes what is left, the
// `flex-shrink` that takes space back when there is none, and the `flex-wrap`
// that starts a second line instead.
//
// Each of the four is what a real page writes. `display:flex; gap:16px` is the
// modern spacing idiom, `justify-content:space-between` is how a navbar puts
// its logo and its menu at the two ends, and a wrapped row is how a card grid
// is built -- so every one of them moves real rects on real pages.
//
// A 400x200 container throughout, 60x20 children unless the row says otherwise.
// Each item reads `x,y WxH` from the container's padding box. Backs
// src/browser/tests/css/flex_line_distribution.html.
(() => {
    const out = {};
    const mk = (label, hostCss, items) => {
        const host = document.createElement('div');
        host.setAttribute('style', hostCss);
        document.body.appendChild(host);
        for (const css of items) {
            const e = document.createElement('div');
            e.setAttribute('style', css);
            host.appendChild(e);
        }
        const hr = host.getBoundingClientRect();
        const rows = [];
        for (const el of host.children) {
            const r = el.getBoundingClientRect();
            rows.push(Math.round(r.x - hr.x) + ',' + Math.round(r.y - hr.y) +
                ' ' + Math.round(r.width) + 'x' + Math.round(r.height));
        }
        out[label] = rows.join(' | ');
        host.remove();
    };
    const ROW = 'display:flex; width:400px; height:200px; margin:0';
    const COL = 'display:flex; flex-direction:column; width:400px; height:200px; margin:0';
    const B = 'width:60px; height:20px';
    const three = [B, B, B];

    mk('gap', ROW + '; gap:20px', three);
    mk('columnGap', ROW + '; column-gap:10px', three);
    mk('gapPct', ROW + '; gap:10%', three);
    mk('gapGrow', ROW + '; gap:20px', ['flex:1;height:20px', 'flex:1;height:20px']);
    mk('gapOne', ROW + '; gap:20px', [B]);
    mk('colGapVertical', COL + '; gap:20px', three);
    mk('blockGapIgnored', 'width:400px; height:200px; gap:20px; margin:0', three);

    mk('justifyStart', ROW + '; justify-content:flex-start', three);
    mk('justifyCenter', ROW + '; justify-content:center', three);
    mk('justifyEnd', ROW + '; justify-content:flex-end', three);
    mk('justifySpaceBetween', ROW + '; justify-content:space-between', three);
    mk('justifySpaceAround', ROW + '; justify-content:space-around', three);
    mk('justifySpaceEvenly', ROW + '; justify-content:space-evenly', three);
    mk('justifyWithGap', ROW + '; justify-content:space-between; gap:20px', three);
    mk('justifyOverfull', ROW + '; justify-content:center', ['width:300px;height:20px', 'width:300px;height:20px']);
    mk('justifyBetweenOne', ROW + '; justify-content:space-between', [B]);
    mk('justifyColumn', COL + '; justify-content:center', three);

    mk('shrink', ROW, ['width:300px;height:20px', 'width:300px;height:20px']);
    mk('shrinkZero', ROW, ['width:300px;height:20px;flex-shrink:0', 'width:300px;height:20px']);
    mk('shrinkUneven', ROW, ['width:300px;height:20px;flex-shrink:1', 'width:300px;height:20px;flex-shrink:3']);
    mk('shrinkWithGap', ROW + '; gap:20px', ['width:300px;height:20px', 'width:300px;height:20px']);

    mk('wrap', ROW + '; flex-wrap:wrap', ['width:150px;height:20px', 'width:150px;height:20px', 'width:150px;height:20px']);
    mk('wrapGap', ROW + '; flex-wrap:wrap; gap:20px', ['width:150px;height:20px', 'width:150px;height:20px', 'width:150px;height:20px']);
    mk('wrapNowrap', ROW + '; flex-wrap:nowrap', ['width:150px;height:20px', 'width:150px;height:20px', 'width:150px;height:20px']);
    mk('wrapAlignStart', ROW + '; flex-wrap:wrap; align-content:flex-start',
       ['width:150px;height:20px', 'width:150px;height:20px', 'width:150px;height:20px']);
    return out;
})()
