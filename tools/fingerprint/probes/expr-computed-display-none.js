// What getComputedStyle reports for an element that has no box at all.
//
// Chrome resolves a used value at layout time, so for an element that took
// part in layout `width` comes back as the px the box actually got. A
// `display:none` element never got a box, so there is no used value to report
// and Chrome falls back to reporting the *declared* value -- `50px` stays
// `50px`, a percentage stays a percentage, and only a genuinely absent
// declaration reports the initial `auto`. Which of those the engine does is
// what this measures, over the box properties a guard walking the whole
// computed style would read.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute; top:0; left:0; width:400px; height:200px;');
    document.body.appendChild(host);

    const PROPS = [
        'width', 'height', 'min-width', 'min-height', 'max-width', 'max-height',
        'inline-size', 'block-size',
        'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
        'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
        'border-top-width', 'border-left-width',
        'top', 'right', 'bottom', 'left',
        'display', 'position', 'font-size', 'line-height',
        'transform', 'text-indent', 'vertical-align', 'background-position',
    ];

    const read = (label, css) => {
        const el = document.createElement('div');
        el.setAttribute('style', css);
        host.appendChild(el);
        const c = getComputedStyle(el);
        const row = {};
        for (const p of PROPS) row[p] = c.getPropertyValue(p);
        out[label] = row;
        el.remove();
    };

    // The same declarations with and without a box, so the diff between the
    // two rows is exactly what layout contributed.
    const decls = {
        Px: 'width:50px; height:30px; margin:5px; padding:4px; border:2px solid; text-indent:7px;',
        Pct: 'width:50%; height:25%; margin:10%; padding:5%; text-indent:10%; line-height:150%;',
        Auto: 'width:auto; height:auto; margin:auto;',
        Bare: '',
        Em: 'font-size:20px; width:3em; height:2em; margin:1em; text-indent:0.5em; line-height:1.5;',
        Calc: 'width:calc(10px + 10%); height:calc(50% - 4px); margin-left:calc(2em + 1px); font-size:16px;',
        MinMax: 'min-width:25%; max-width:60%; min-height:10%; max-height:4em; font-size:16px;',
        Abs: 'position:absolute; top:10%; left:25%; width:50px; height:30px;',
        Transform: 'width:50px; height:30px; transform:translateX(50%) rotate(30deg);',
        Vert: 'width:50px; height:30px; vertical-align:20%; background-position:25% 75%;',
    };
    for (const [k, css] of Object.entries(decls)) {
        read('shown' + k, css);
        read('none' + k, 'display:none; ' + css);
    }

    // A box-less element by way of an unattached tree, for contrast: the
    // element is not `display:none`, it simply is not in a document with a
    // browsing context.
    const orphan = document.createElement('div');
    orphan.setAttribute('style', 'width:50px; height:30px; margin:5px;');
    {
        const c = getComputedStyle(orphan);
        const row = {};
        for (const p of PROPS) row[p] = c.getPropertyValue(p);
        out.detached = row;
    }

    // An element whose *ancestor* is display:none, so the element itself
    // computes `display:block` yet still has no box.
    {
        const wrap = document.createElement('div');
        wrap.setAttribute('style', 'display:none;');
        const el = document.createElement('div');
        el.setAttribute('style', 'width:50px; height:30px; margin:5px; padding:4px;');
        wrap.appendChild(el);
        host.appendChild(wrap);
        const c = getComputedStyle(el);
        const row = {};
        for (const p of PROPS) row[p] = c.getPropertyValue(p);
        out.underNoneParent = row;
        wrap.remove();
    }

    out.viewport = [window.innerWidth, window.innerHeight];
    host.remove();
    return out;
})()
