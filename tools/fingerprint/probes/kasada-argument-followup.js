// The differences the wide probe (kasada-argument-answers.js) turned up, each
// put back under conditions that say which half of it is real: the WebGL
// renderer strings read both before and after the extension that is supposed to
// gate them, the image types read against the ones Chrome does encode, the
// events read against ones both arms build.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/kasada-argument-followup.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/kasada-argument-followup.js --url https://example.com/
(() => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'threw:' + (e && e.name); } };

    for (const v of ['webgl', 'webgl2']) {
        const gl = document.createElement('canvas').getContext(v);
        t(v + '.before.37446', () => (gl ? gl.getParameter(37446) : 'no-ctx'));
        t(v + '.before.37445', () => (gl ? gl.getParameter(37445) : 'no-ctx'));
        t(v + '.ext', () => (gl ? !!gl.getExtension('WEBGL_debug_renderer_info') : 'no-ctx'));
        t(v + '.after.37446', () => (gl ? gl.getParameter(37446) : 'no-ctx'));
        t(v + '.after.37445', () => (gl ? gl.getParameter(37445) : 'no-ctx'));
        t(v + '.VENDOR', () => (gl ? gl.getParameter(0x1F00) : 'no-ctx'));
        t(v + '.RENDERER', () => (gl ? gl.getParameter(0x1F01) : 'no-ctx'));
    }

    const c = document.createElement('canvas');
    c.width = 20; c.height = 20;
    const ctx = c.getContext('2d');
    if (ctx) { ctx.fillStyle = '#4285f4'; ctx.fillRect(2, 2, 16, 16); }
    for (const m of ['image/png', 'image/jpeg', 'image/webp', 'image/bmp', 'image/gif', 'image/avif']) {
        t('toDataURL ' + m, () => c.toDataURL(m).slice(0, c.toDataURL(m).indexOf(';')));
    }
    t('convertToBlob', () => (typeof OffscreenCanvas === 'undefined' ? 'none' : 'have'));

    for (const e of ['TouchEvent', 'MouseEvent', 'UIEvent', 'CustomEvent', 'KeyboardEvent']) {
        t('createEvent ' + e, () => Object.prototype.toString.call(document.createEvent(e)));
    }

    t('devicePixelRatio', () => devicePixelRatio);
    t('mq 1dppx', () => matchMedia('(min-resolution: 1dppx)').matches);
    t('mq 1dppx media', () => matchMedia('(min-resolution: 1dppx)').media);
    t('mq res=1dppx', () => matchMedia('(resolution: 1dppx)').matches);
    t('mq 96dpi', () => matchMedia('(min-resolution: 96dpi)').matches);
    t('mq bogus', () => matchMedia('(min-bogus: 1px)').matches);
    t('mq bogus media', () => matchMedia('(min-bogus: 1px)').media);
    t('mq color-index', () => matchMedia('(color-index: 0)').matches);
    t('mq device-posture', () => matchMedia('(device-posture: continuous)').matches);
    t('innerWidth', () => innerWidth);
    t('innerHeight', () => innerHeight);
    t('screen', () => screen.width + 'x' + screen.height);
    return JSON.stringify(out);
})()
