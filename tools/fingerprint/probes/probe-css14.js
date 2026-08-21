// The layer grammar, both directions, on values chosen to hit every corner of
// it: the position's one-to-four components and their order, the `/` and where
// it may sit, the box pair, the colour that belongs to the whole value rather
// than to a layer, and the comma that separates layers.
//
// The table behind this is measured by dump-css-shorthands.mjs, but the table is
// only half of what a page sees: each stored longhand value then goes through
// the value canonicaliser, so this is the reading that says the two halves
// agree with Chrome together. A value the engine declines shows up here as one
// entry where Chrome has nine.
(() => {
    const values = [
        // one component at a time, to each slot
        'blue', '#abc', 'currentColor', 'rgb(1, 2, 3)', 'none',
        'url("a")', 'url(a)', 'linear-gradient(red, blue)',
        'no-repeat', 'repeat-x', 'space', 'round',
        'scroll', 'fixed', 'local',
        'content-box', 'border-box', 'padding-box', 'text',
        // the position
        'center', 'top', 'left', 'right', 'bottom', '10px', '50%', '0',
        'top right', 'right top', 'left top', 'top left', 'center center',
        'center top', 'top center', '10px 20px', '10px center', 'center 10px',
        '50% 50%', 'left 10px', '10px left', 'left center', 'center left',
        'left 10px top 20px', 'right 10px bottom 20px', 'left top 20px',
        'left 10px top', 'top 20px left 10px', 'center top 10px',
        'top 10px center', 'left 10px center', 'center 10px top',
        'left center 10px', 'center center 10px', 'left 10px right 20px',
        'left top 10px 20px', '10px 20px 30px',
        // the slash
        '10px / 20px', 'center / cover', 'center / contain', '/ cover',
        '10px / auto', 'left top / 10px 20px', 'left 10px top 20px / cover',
        'center / 10px', 'url("a") / 20px', 'no-repeat / 20px',
        '10px no-repeat / 20px', 'center no-repeat / cover', 'url(a) 0/0',
        '10px 20px / 30px 40px',
        // the box pair
        'padding-box border-box', 'border-box padding-box',
        'content-box content-box', 'border-box content-box',
        'text border-box', 'padding-box text', 'border-area',
        // whole layers, in any order
        'url("a") no-repeat', 'no-repeat url("a")', 'red url("a")',
        'url("a") red', 'red url("a") no-repeat', 'none red', 'red 10px',
        'left 10px no-repeat', 'left top no-repeat',
        'no-repeat left 10px top 20px', 'local no-repeat',
        'url("a") no-repeat center / cover',
        'url("a") center / cover no-repeat fixed padding-box border-box red',
        'repeat no-repeat', 'no-repeat repeat', 'space round',
        // the comma
        'red, blue', 'url("a"), url("b")', 'url("a"), url("b") blue',
        'url("a") blue, url("b")', 'url("a"), red', 'url("a"), url("b"), url("c")',
        'url("a"), url("b"), url("c") red', 'no-repeat, repeat-x', 'none, none',
        '10px 20px, 30px', 'padding-box, border-box',
        'padding-box border-box, content-box',
        'url("a") center / cover, url("b") left top / contain',
        'url("a") no-repeat, url("b") fixed, url("c") padding-box',
        'url("a") fixed, url("b") local', 'repeat no-repeat, space round',
        // and the CSS-wide keywords, which reach every longhand as themselves
        'inherit', 'initial', 'unset', 'revert', 'revert-layer',
    ];

    const out = {};
    for (const value of values) {
        const el = document.createElement('div');
        el.style.setProperty('background', value);
        const names = [];
        for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
        out[value] = {
            items: names,
            values: names.map((n) => el.style.getPropertyValue(n)),
            read: el.style.getPropertyValue('background'),
            cssText: el.style.cssText,
        };
    }
    return out;
})()
