// Which value classes does `color` accept, measured the way
// dump-css-shorthands.mjs measures them?
//
// The generated `value_classes` table has no entry for `color`, because the
// generator only walks the longhands of the 230 shorthands it probes and
// nothing expands to `color`. With no entry, `refusesLonghand` skips its
// grammar check entirely, which is why `color: FakeColor` is stored here and
// dropped by Chrome — the tell Kasada plants at x-hyatt.
//
// Same tokens as the generator's CLASS_TOKENS, so the answer can be written in
// the same vocabulary, plus the identifiers this is actually about.
(() => {
    const CLASS_TOKENS = {
        length: '1px', percent: '1%', number: '2', angle: '45deg', time: '1s',
        url: 'url(a)', string: '"str"', identifier: 'MyIdentXyz', colour: '#abc',
        function: 'rgb(1, 2, 3)', gradient: 'linear-gradient(red, blue)',
        image: 'image-set("a" 1x)',
    };
    const el = document.createElement('div');
    const set = (prop, token) => {
        el.style.cssText = '';
        el.style.setProperty(prop, token);
        return el.style.getPropertyValue(prop) !== '';
    };
    const out = { accepted: [], refused: [] };
    for (const [cls, token] of Object.entries(CLASS_TOKENS)) {
        (set('color', token) ? out.accepted : out.refused).push(cls + '=' + token);
    }
    for (const t of ['red', 'currentcolor', 'buttonface', 'ButtonFace', 'FakeColor',
        '-moz-ButtonDefault', 'inherit', 'initial', 'unset', 'revert', 'transparent',
        'color-mix(in srgb, red, blue)', 'light-dark(red, blue)', 'rgb(1 2 3 / 40%)']) {
        (set('color', t) ? out.accepted : out.refused).push('lit=' + t);
    }
    return out;
})();
