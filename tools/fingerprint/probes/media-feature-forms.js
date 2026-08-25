// The same media feature written every way the spec allows, because the wide
// probe (kasada-argument-answers.js) could not tell which half of a difference
// was the feature and which was the way it was written: it uses the exact
// strings Kasada passed, and those have no space after the colon.
//
// Reports `matches | media` for each, because the serialization is a reading of
// its own -- Chrome normalizes `(min-width:100px)` to `(min-width: 100px)` and
// `2.125` to `2.125 / 1`, and an engine that echoes the input back says so on
// every query the page makes.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/media-feature-forms.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/media-feature-forms.js --url https://example.com/
(() => {
    const out = {};
    const qs = [
        '(min-resolution: 0.625dppx)', '(min-resolution:0.625dppx)',
        '(min-resolution: 1dppx)', '(min-resolution:1dppx)',
        '(min-resolution: 2dppx)', '(min-resolution:2dppx)',
        '(min-resolution: 50dpi)', '(min-resolution:50dpi)',
        '(max-resolution: 256dpi)', '(max-resolution:256dpi)',
        '(resolution: 1dppx)', '(resolution = 1dppx)', '(resolution > 50dpi)', '(resolution < 50dpi)',
        '(min-width: 100px)', '(min-width:100px)', '(max-width: 5000px)', '(max-width:5000px)',
        '(color-index: 0)', '(max-color-index: 4)', '(min-color-index: 0)', '(color-index = 0)',
        '(color: 8)', '(min-color: 8)', '(max-color: 8)', '(color = 8)', '(color > 4)',
        '(min-aspect-ratio: 1/2)', '(max-aspect-ratio: 2.125)', '(aspect-ratio = 1.7)',
        '(min-device-aspect-ratio: 1/2)', '(max-device-aspect-ratio: 2.125)',
        '(device-posture: continuous)', '(device-posture: folded)',
        '(width > 100px)', '(width < 5000px)', '(height > 100px)',
        '(update: fast)', '(scripting: enabled)', '(overflow-block: scroll)',
    ];
    for (const q of qs) {
        try {
            const m = matchMedia(q);
            out[q] = m.matches + ' | ' + m.media;
        } catch (e) { out[q] = 'threw:' + (e && e.name); }
    }
    return JSON.stringify(out);
})()
