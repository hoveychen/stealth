// What opens the WEBGL_debug_renderer_info gate and what does not. The wide
// probe (kasada-argument-followup.js) shows that getParameter(37445/37446)
// answers null before the extension is asked for; this one pins down the shape
// of the gate itself -- whether it is per-context or per-page, whether merely
// listing the extensions opens it, whether a different extension does, and how
// the name is matched.
//
// Two rows still differ from Chrome, and neither is the gate: `otherExt` is
// false here because a void-payload extension marshals to undefined instead of
// Chrome's named interface object, and `gated.getError` is 0 because getError
// is a constant NO_ERROR while Chrome records INVALID_ENUM for the gated read.
// Both are their own gaps.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/webgl-debug-renderer-gate.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/webgl-debug-renderer-gate.js --url https://example.com/
(() => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'threw:' + (e && e.name); } };

    // Two independent webgl1 contexts: enable on A, read on B.
    const a = document.createElement('canvas').getContext('webgl');
    const b = document.createElement('canvas').getContext('webgl');
    t('A.ext', () => !!a.getExtension('WEBGL_debug_renderer_info'));
    t('A.after', () => a.getParameter(37446));
    t('B.after-A-enabled', () => b.getParameter(37446));

    // Same canvas, getContext twice -> same context object?
    const c = document.createElement('canvas');
    const c1 = c.getContext('webgl');
    const c2 = c.getContext('webgl');
    t('sameCanvasSameCtx', () => c1 === c2);

    // Casing of the extension name.
    const d = document.createElement('canvas').getContext('webgl');
    t('lowercase.ext', () => !!d.getExtension('webgl_debug_renderer_info'));
    t('lowercase.then37446', () => d.getParameter(37446));

    // Does getSupportedExtensions alone open the gate?
    const e = document.createElement('canvas').getContext('webgl');
    t('supported.len', () => e.getSupportedExtensions().length);
    t('supported.then37446', () => e.getParameter(37446));

    // A different extension must not open it.
    const f = document.createElement('canvas').getContext('webgl');
    t('otherExt', () => !!f.getExtension('OES_texture_float'));
    t('otherExt.then37446', () => f.getParameter(37446));

    // getError after a gated read, and the 37445/37446 typeof.
    const g = document.createElement('canvas').getContext('webgl');
    t('gated.typeof', () => typeof g.getParameter(37446));
    t('gated.getError', () => g.getError());

    // webgl2 gate independent of webgl1 on a fresh canvas.
    const h = document.createElement('canvas').getContext('webgl2');
    t('gl2.before', () => h.getParameter(37445));
    t('gl2.ext', () => !!h.getExtension('WEBGL_debug_renderer_info'));
    t('gl2.after', () => h.getParameter(37445));

    return JSON.stringify(out);
})()
