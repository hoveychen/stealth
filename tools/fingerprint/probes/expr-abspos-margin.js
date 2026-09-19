// Where an out-of-flow box's margins put it. An inset names where the MARGIN
// box goes, so `position:absolute; left:0; margin-left:30px` puts the border box
// at 30 -- and with both insets on an axis declared, an `auto` margin takes the
// leftover, which is how `left:0; right:0; margin:0 auto` centres an overlay.
//
// Eleven shapes in a 400x200 relatively positioned parent, each reading the
// border box's offset from that parent. Backs the layout half of
// src/browser/tests/css/computed_auto_margin.html; the reported values are
// tools/fingerprint/probes/expr-auto-margin-used.js.
(() => {
    const host = document.createElement('div');
    host.setAttribute('style', 'width:400px; height:200px; position:relative; margin:0');
    document.body.appendChild(host);
    const out = {};
    const read = (label, css) => {
        const el = document.createElement('div');
        el.setAttribute('style', css);
        host.appendChild(el);
        const r = el.getBoundingClientRect(), hr = host.getBoundingClientRect();
        out[label] = [Math.round((r.x - hr.x) * 100) / 100, Math.round((r.y - hr.y) * 100) / 100];
        el.remove();
    };
    const A = 'position:absolute; width:100px; height:20px;';
    read('leftOnlyFixedMargin', A + ' left:0; margin-left:30px');
    read('leftOnlyAutoMargin', A + ' left:0; margin-left:auto');
    read('rightOnlyFixedMargin', A + ' right:0; margin-right:30px');
    read('bothInsetsAutoBoth', A + ' left:0; right:0; margin:0 auto');
    read('bothInsetsAutoLeft', A + ' left:0; right:0; margin-left:auto');
    read('bothInsetsAutoRight', A + ' left:0; right:0; margin-right:auto');
    read('bothInsetsNoAuto', A + ' left:0; right:0');
    read('bothInsetsFixedMargin', A + ' left:0; right:0; margin-left:30px');
    read('vertBothAuto', A + ' top:0; bottom:0; margin:auto 0');
    read('topOnlyFixedMargin', A + ' top:0; margin-top:30px');
    read('noInsetFixedMargin', A + ' margin-left:30px; margin-top:12px');
    host.remove();
    return out;
})()
