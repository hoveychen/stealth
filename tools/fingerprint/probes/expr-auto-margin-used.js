// What an `auto` margin computes to. Chrome reports a USED margin, so an `auto`
// one comes back as the px it actually took -- `margin: 0 auto` on a 100px box
// in a 400px parent is `150px` a side, not `auto`. Which boxes have a used
// margin at all is the part worth measuring: an inline box and a `display:none`
// element keep `auto`, and everything else resolves.
//
// Reads the four margins plus the width, and the placement the same declaration
// produces, so the reported value and the layout can be checked against each
// other. Backs src/browser/tests/css/computed_auto_margin.html.
(() => {
    const host = document.createElement('div');
    host.setAttribute('style', 'width:400px; height:200px; position:relative; margin:0');
    document.body.appendChild(host);
    const M = ['margin-top', 'margin-right', 'margin-bottom', 'margin-left', 'width'];
    const out = {};
    const read = (label, css, parent) => {
        const el = document.createElement('div');
        el.setAttribute('style', css);
        (parent ?? host).appendChild(el);
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        const hr = (parent ?? host).getBoundingClientRect();
        out[label] = M.map((n) => cs.getPropertyValue(n)).join(' | ') +
            '  @x=' + Math.round((r.x - hr.x) * 100) / 100;
        el.remove();
    };
    read('autoAllAutoWidth', 'margin:auto');
    read('autoAllFixedWidth', 'margin:auto; width:100px');
    read('autoSidesFixedWidth', 'margin-left:auto; margin-right:auto; width:100px');
    read('autoLeftOnly', 'margin-left:auto; width:100px');
    read('autoRightOnly', 'margin-right:auto; width:100px');
    read('autoTopBottom', 'margin-top:auto; margin-bottom:auto; width:100px');
    read('mixedAuto', 'margin-left:auto; margin-right:10px; width:100px');
    read('declared', 'margin:5px 10px; width:100px');
    read('floatAuto', 'float:left; margin:auto; width:100px');
    read('inlineBlockAuto', 'display:inline-block; margin:auto; width:100px');
    read('absAutoSides', 'position:absolute; left:0; right:0; margin-left:auto; margin-right:auto; width:100px');
    read('absAutoAll', 'position:absolute; top:0; bottom:0; left:0; right:0; margin:auto; width:100px; height:50px');
    read('absAutoNoInsets', 'position:absolute; margin:auto; width:100px; height:50px');
    read('absCentredShorthand', 'position:absolute; left:0; right:0; margin:0 auto; width:100px; height:20px');
    read('inlineAuto', 'display:inline; margin:auto');
    read('noneAuto', 'display:none; margin:auto; width:100px');
    // The flex algorithm's own rule, measured but deliberately out of the test's
    // scope: an `auto` margin there absorbs free space on both axes.
    read('flexItemAuto', 'margin:auto; width:100px', (() => {
        const f = document.createElement('div');
        f.setAttribute('style', 'display:flex; width:400px; height:200px');
        host.appendChild(f);
        return f;
    })());
    host.remove();
    return out;
})()
