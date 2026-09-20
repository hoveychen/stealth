// What a flex COLUMN does with its main axis. Its main axis is the block one,
// so the stacking walk lays it out -- and the stacking walk knows nothing about
// `gap`, `justify-content`, `flex-shrink` or a main-axis `auto` margin. A
// sidebar, a card stack, a modal's button column: every one of them is
// `display:flex; flex-direction:column; gap:12px` on a real page.
//
// A 400x200 container throughout, 60x20 children unless the row says otherwise.
// Each item reads `x,y WxH` from the container's padding box. Backs
// src/browser/tests/css/flex_column_direction.html.
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
    const COL = 'display:flex; flex-direction:column; width:400px; height:200px; margin:0';
    const B = 'width:60px; height:20px';
    const three = [B, B, B];

    // The gap on a column's main axis is `row-gap`, which the `gap` shorthand
    // expands to; `column-gap` is the CROSS axis there and a nowrap column has
    // no second line for it to separate.
    mk('gap', COL + '; gap:20px', three);
    mk('rowGap', COL + '; row-gap:10px', three);
    mk('columnGapCross', COL + '; column-gap:20px', three);
    mk('gapPct', COL + '; gap:10%', three);
    mk('gapGrow', COL + '; gap:20px', ['flex:1;width:60px', 'flex:1;width:60px']);
    mk('gapOne', COL + '; gap:20px', [B]);

    mk('justifyStart', COL + '; justify-content:flex-start', three);
    mk('justifyCenter', COL + '; justify-content:center', three);
    mk('justifyEnd', COL + '; justify-content:flex-end', three);
    mk('justifyBetween', COL + '; justify-content:space-between', three);
    mk('justifyAround', COL + '; justify-content:space-around', three);
    mk('justifyEvenly', COL + '; justify-content:space-evenly', three);
    mk('justifyWithGap', COL + '; justify-content:space-between; gap:20px', three);
    mk('justifyOverfull', COL + '; justify-content:center',
        ['width:60px;height:150px', 'width:60px;height:150px']);

    // The cross axis of a column is the inline one: `align-items` decides how
    // wide an item with no width of its own ends up, and where a narrower one
    // sits.
    const N = 'height:20px';
    mk('alignStretch', COL, [N, N]);
    mk('alignStart', COL + '; align-items:flex-start', [B, B]);
    mk('alignCenter', COL + '; align-items:center', [B, B]);
    mk('alignEnd', COL + '; align-items:flex-end', [B, B]);

    // A main-axis `auto` margin takes the free space before
    // `justify-content` sees any of it.
    mk('marginAuto', COL, [B.replace('width', 'margin:auto; width')]);
    mk('marginTopAuto', COL, ['margin-top:auto; ' + B]);
    mk('marginBottomAuto', COL, ['margin-bottom:auto; ' + B]);
    mk('marginAutoSibling', COL, ['margin-top:auto; ' + B, B]);

    // Over-full on the block axis: the items shrink the same way a row's do.
    mk('shrink', COL, ['width:60px;height:150px', 'width:60px;height:150px']);
    mk('shrinkZero', COL,
        ['width:60px;height:150px;flex-shrink:0', 'width:60px;height:150px']);

    // The control: a BLOCK container ignores every one of these.
    mk('blockGapIgnored', 'width:400px; height:200px; gap:20px; margin:0', three);
    mk('blockJustifyIgnored', 'width:400px; height:200px; justify-content:center; margin:0', three);

    return out;
})()
