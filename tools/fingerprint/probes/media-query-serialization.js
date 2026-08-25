// What `matchMedia(q).media` gives back for each form of q: Chrome re-serialises
// the parsed query rather than echoing the input, so every deviation from the
// input text is a rule we have to reproduce. `matches` rides along because a
// serialisation change must not move it.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/media-query-serialization.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/media-query-serialization.js --url https://example.com/
(() => {
    const out = {};
    const queries = [
        // spacing around the colon and inside the parens
        '(min-width:100px)',
        '(min-width : 100px)',
        '(  min-width  :  100px  )',
        '( min-width:100px )',
        'screen and (min-width:100px)',
        'screen,print',
        'screen , print',
        'not screen and (min-width:100px)',
        'only screen and (min-width:100px)',
        // case
        '(MIN-WIDTH: 100PX)',
        '(Min-Width: 100px)',
        'SCREEN AND (MIN-WIDTH: 100px)',
        'NOT SCREEN',
        'ONLY SCREEN',
        '(min-resolution: 1DPPX)',
        '(min-resolution: 96DPI)',
        // numbers
        '(min-width: 100.0px)',
        '(min-width: 0100px)',
        '(min-width: +100px)',
        '(min-width: 1e2px)',
        '(min-width: 100.50px)',
        '(min-resolution: .625dppx)',
        '(min-resolution: 0.6250dppx)',
        '(min-width: 0px)',
        '(min-width: -0px)',
        '(color: 08)',
        // ratios
        '(min-aspect-ratio: 1/2)',
        '(min-aspect-ratio: 1 / 2)',
        '(min-aspect-ratio: 1  /  2)',
        '(min-aspect-ratio: 1.5/2.5)',
        '(aspect-ratio: 1.5)',
        '(aspect-ratio: 2)',
        '(aspect-ratio: 16/9)',
        '(device-aspect-ratio: 16/9)',
        '(aspect-ratio > 1.5)',
        '(aspect-ratio >= 16/9)',
        // range forms
        '(width>100px)',
        '(width >100px)',
        '(width>= 100px)',
        '(100px<width)',
        '(100px<=width<=200px)',
        '(100px < width < 200px)',
        '(width=100px)',
        '(resolution>1dppx)',
        // boolean forms
        '(color)',
        '(hover)',
        '(COLOR)',
        '(monochrome)',
        // discrete keywords
        '(orientation:landscape)',
        '(orientation: LANDSCAPE)',
        '(prefers-color-scheme:dark)',
        '(any-hover:none)',
        '(display-mode:browser)',
        // unknown / invalid
        '(min-bogus: 1px)',
        '(bogus)',
        '(min-width: bogus)',
        '(min-width:)',
        '(min-width: 100)',
        '(min-width: 100foo)',
        'bogus',
        'not bogus',
        'screen and (min-width: 100px) and (max-width: 5000px)',
        'screen and bogus',
        '',
        '   ',
        '(',
        ')',
        '((min-width: 100px))',
        'all',
        'not all',
        // comments and stray whitespace
        '/*c*/(min-width:100px)',
        '(min-width:/*c*/100px)',
        '  (min-width:100px)  ',
        '\t(min-width:100px)\n',
        // a discrete feature's own keyword set is what decides: a value
        // outside it is quoted rather than canonicalised, even though both
        // answer false
        '(pointer:coarse)',
        '(orientation:bogus)',
        '(prefers-color-scheme:BOGUS)',
        '(hover:none)',
        '(scan:INTERLACE)',
        '(update:SLOW)',
        '(display-mode:FULLSCREEN)',
        '(device-posture:FOLDED)',
        '(color-gamut:P3)',
        '(dynamic-range:HIGH)',
        '(forced-colors:ACTIVE)',
        '(prefers-contrast:MORE)',
        '(scripting:NONE)',
        '(overflow-block:PAGED)',
        '(overflow-inline:NONE)',
        // integers are integers, and grid is 0 or 1
        '(color: 8.0)',
        '(color:0x8)',
        '(monochrome:00)',
        '(grid:1)',
        '(grid:2)',
        // the boolean form belongs to the unprefixed spelling only
        '(min-width)',
        '(device-posture)',
        // lengths, resolutions and ratios
        '(min-width: 0)',
        '(min-width:6.25em)',
        '(min-width:1REM)',
        '(min-resolution:1DPCM)',
        '(resolution:1X)',
        '(aspect-ratio: 016 / 009)',
        '(aspect-ratio:1/0)',
        '(min-aspect-ratio:.5)',
        // nesting, `or`, and the forms with no valid reading
        '(((min-width:100px)))',
        '((min-width:100px) and (max-width:200px))',
        'not ((min-width:100px))',
        '(min-width:1px) or (min-width:2px)',
        'screen and (min-width:1px) or (min-width:2px)',
        'screen and (min-width:100px) and (bogus)',
        'all and (min-width:100px)',
        'not all and (min-width:100px)',
        'bogus and (min-width:100px)',
        'only bogus',
        'not screen,print',
        '(min-width:100px),,(max-width:200px)',
        // nesting / logic
        'not (min-width: 100px)',
        '(min-width: 100px) and (max-width: 200px)',
        '(min-width: 100px), (max-width: 200px)',
    ];
    for (const q of queries) {
        try {
            const m = matchMedia(q);
            out[q] = m.matches + ' | ' + m.media;
        } catch (e) {
            out[q] = 'threw:' + (e && e.name);
        }
    }
    return JSON.stringify(out);
})()
