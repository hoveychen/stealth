// Where a flex container puts its children, and what size the cross axis gives
// them. The main-axis SIZE already worked (`flexItemWidth` distributes the
// line), so this is only about position and the cross axis -- and without those
// a flex row stacked its children vertically, one under the next, exactly as a
// block would.
//
// A 400x200 container throughout, children 60x20 unless the row says otherwise,
// so every number below is a share of 400 on the main axis and of 200 on the
// cross one. Each item reads as `x,y WxH` relative to the container's padding
// box. Backs src/browser/tests/css/flex_line_placement.html.
(() => {
    const out = {};
    const mk = (label, hostCss, childCss) => {
        const host = document.createElement('div');
        host.setAttribute('style', hostCss);
        document.body.appendChild(host);
        for (const css of childCss) {
            const el = document.createElement('div');
            el.setAttribute('style', css);
            host.appendChild(el);
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

    mk('row', ROW, three);
    mk('column', COL, three);
    mk('inlineFlexRow', 'display:inline-flex; width:400px; height:200px; margin:0', three);
    mk('block', 'width:400px; height:200px; margin:0', three);
    mk('rowGrow', ROW, ['flex:1; height:20px', 'flex:1; height:20px', 'flex:1; height:20px']);
    mk('rowUnevenWidths', ROW, ['width:30px;height:20px', 'width:150px;height:20px', 'width:20px;height:20px']);
    mk('rowWithMargins', ROW, ['width:60px;height:20px;margin:0 10px', 'width:60px;height:20px;margin:0 10px']);
    mk('rowPadded', 'display:flex; width:400px; height:200px; padding:15px; margin:0', [B, B]);
    mk('rowOverflow', ROW, ['width:300px;height:20px', 'width:300px;height:20px']);

    // The cross axis. `stretch` is the initial `align-items`, so a child with no
    // height declared fills the container.
    mk('crossStretchDefault', ROW, ['width:60px', 'width:60px']);
    mk('crossStretchDeclared', ROW + '; align-items:stretch', ['width:60px', 'width:60px']);
    mk('crossFlexStart', ROW + '; align-items:flex-start', ['width:60px', 'width:60px']);
    mk('crossCenter', ROW + '; align-items:center', [B, B]);
    mk('crossFlexEnd', ROW + '; align-items:flex-end', [B, B]);
    mk('crossStretchWithHeight', ROW, [B, B]);
    mk('crossAlignSelf', ROW + '; align-items:flex-start',
       [B, 'width:60px;height:20px;align-self:flex-end']);
    mk('columnCrossStretch', COL, ['height:20px', 'height:20px']);
    return out;
})()
