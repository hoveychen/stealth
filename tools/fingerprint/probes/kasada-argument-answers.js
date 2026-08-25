// Every question Kasada asked on x-hyatt that has an argument and an answer,
// put to both arms in one pass. Generated from the --args read log
// (tools/fingerprint/results/prop-reads-hyatt-args.json, one settle of
// https://www.hyatt.com/); regenerate it from a fresh log rather than editing
// the lists by hand.
//
// Left out on purpose: the calls whose answer is not a reading of the engine.
// TextEncoder.encode, btoa and SubtleCrypto.digest are arithmetic, rotate and
// translate return nothing, Storage and Performance.getEntriesByType answer
// about the page rather than the browser.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/kasada-argument-answers.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/kasada-argument-answers.js --url https://example.com/
(() => {
    const out = {};
    const take = (key, fn) => {
        try {
            out[key] = fn();
        } catch (e) {
            out[key] = 'threw:' + (e && e.name);
        }
    };

    // 227 queries, 64 of which are one devicePixelRatio binary search run three
    // times over -- dppx, then dpi, then dpcm. A engine that answers a
    // resolution feature wrongly converges the search on a value no browser
    // reports.
    for (const q of ["(min-resolution:5dppx)","(min-resolution:2.5dppx)","(min-resolution:1.25dppx)","(min-resolution:0.625dppx)","(min-resolution:0.3125dppx)","(min-resolution:0.15625dppx)","(min-resolution:0.078125dppx)","(min-resolution:0.0390625dppx)","(min-resolution:0.01953125dppx)","(min-resolution:0.009765625dppx)","(min-resolution:0.0048828125dppx)","(min-resolution:0.00244140625dppx)","(min-resolution:0.001220703125dppx)","(min-resolution:0.0006103515625dppx)","(min-resolution:0.00030517578125dppx)","(min-resolution:0.000152587890625dppx)","(min-resolution:0.0000762939453125dppx)","(min-resolution:0.00003814697265625dppx)","(min-resolution:0.000019073486328125dppx)","(min-resolution:0.0000095367431640625dppx)","(min-resolution:0.00000476837158203125dppx)","(min-resolution:0.000002384185791015625dppx)","(min-resolution:0.0000011920928955078125dppx)","(min-resolution:5.960464477539062e-7dppx)","(min-resolution:500dpi)","(min-resolution:250dpi)","(min-resolution:125dpi)","(min-resolution:62.5dpi)","(min-resolution:31.25dpi)","(min-resolution:15.625dpi)","(min-resolution:7.8125dpi)","(min-resolution:3.90625dpi)","(min-resolution:1.953125dpi)","(min-resolution:0.9765625dpi)","(min-resolution:0.48828125dpi)","(min-resolution:0.244140625dpi)","(min-resolution:0.1220703125dpi)","(min-resolution:0.06103515625dpi)","(min-resolution:0.030517578125dpi)","(min-resolution:0.0152587890625dpi)","(min-resolution:0.00762939453125dpi)","(min-resolution:0.003814697265625dpi)","(min-resolution:0.0019073486328125dpi)","(min-resolution:0.00095367431640625dpi)","(min-resolution:200dpcm)","(min-resolution:100dpcm)","(min-resolution:50dpcm)","(min-resolution:25dpcm)","(min-resolution:12.5dpcm)","(min-resolution:6.25dpcm)","(min-resolution:3.125dpcm)","(min-resolution:1.5625dpcm)","(min-resolution:0.78125dpcm)","(min-resolution:0.390625dpcm)","(min-resolution:0.1953125dpcm)","(min-resolution:0.09765625dpcm)","(min-resolution:0.048828125dpcm)","(min-resolution:0.0244140625dpcm)","(min-resolution:0.01220703125dpcm)","(min-resolution:0.006103515625dpcm)","(min-resolution:0.0030517578125dpcm)","(min-resolution:0.00152587890625dpcm)","(min-resolution:0.000762939453125dpcm)","(min-resolution:0.0003814697265625dpcm)","(hover: none)","(hover: hover)","(forced-colors: none)","(forced-colors: active)","(update: none)","(update: slow)","(update: fast)","(overflow-inline: none)","(overflow-inline: scroll)","(orientation: portrait)","(orientation: landscape)","(any-hover: none)","(any-hover: hover)","(scripting: none)","(scripting: initial-only)","(scripting: enabled)","(device-height = 0px)","(device-height = 8192px)","(device-height > 8192px)","(device-height < 0px)","(min-device-height: 4096px)","(max-device-height: 4096px)","(min-device-height: 2048px)","(max-device-height: 2048px)","(min-device-height: 1024px)","(max-device-height: 1024px)","(min-device-height: 1536px)","(max-device-height: 1536px)","(min-device-height: 1280px)","(max-device-height: 1280px)","(min-device-height: 1152px)","(max-device-height: 1152px)","(min-device-height: 1088px)","(max-device-height: 1088px)","(min-device-height: 1056px)","(max-device-height: 1056px)","(min-device-height: 1072px)","(max-device-height: 1072px)","(min-device-height: 1080px)","(max-device-height: 1080px)","(display-mode: browser)","(display-mode: fullscreen)","(display-mode: minimal-ui)","(display-mode: picture-in-picture)","(display-mode: standalone)","(display-mode: window-controls-overlay)","(color = 0)","(color = 64)","(color > 64)","(color < 0)","(min-color: 32)","(max-color: 32)","(min-color: 16)","(max-color: 16)","(min-color: 8)","(max-color: 8)","(color-index = 0)","(color-index = 8)","(color-index > 8)","(color-index < 0)","(min-color-index: 4)","(max-color-index: 4)","(video-dynamic-range: standard)","(video-dynamic-range: high)","(prefers-reduced-motion: no-preference)","(prefers-reduced-motion: reduce)","(prefers-contrast: no-preference)","(prefers-contrast: more)","(prefers-contrast: less)","(prefers-contrast: custom)","(device-posture: continuous)","(device-posture: folded)","(dynamic-range: standard)","(dynamic-range: high)","(device-width = 0px)","(device-width = 8192px)","(device-width > 8192px)","(device-width < 0px)","(min-device-width: 4096px)","(max-device-width: 4096px)","(min-device-width: 2048px)","(max-device-width: 2048px)","(min-device-width: 1024px)","(max-device-width: 1024px)","(min-device-width: 1536px)","(max-device-width: 1536px)","(min-device-width: 1792px)","(max-device-width: 1792px)","(min-device-width: 1920px)","(max-device-width: 1920px)","(device-aspect-ratio = 0.25)","(device-aspect-ratio = 4)","(device-aspect-ratio > 4)","(device-aspect-ratio < 0.25)","(min-device-aspect-ratio: 2.125)","(max-device-aspect-ratio: 2.125)","(resolution = 0dpi)","(resolution = 512dpi)","(resolution > 512dpi)","(resolution < 0dpi)","(min-resolution: 256dpi)","(max-resolution: 256dpi)","(any-pointer: none)","(any-pointer: coarse)","(any-pointer: fine)","(overflow-block: none)","(overflow-block: scroll)","(overflow-block: optional-paged)","(overflow-block: paged)","(color-gamut: srgb)","(color-gamut: p3)","(color-gamut: rec2020)","(height = 0px)","(height = 8000px)","(height > 8000px)","(height < 0px)","(min-height: 4000px)","(max-height: 4000px)","(min-height: 2000px)","(max-height: 2000px)","(min-height: 1000px)","(max-height: 1000px)","(min-height: 1500px)","(max-height: 1500px)","(min-height: 1250px)","(max-height: 1250px)","(min-height: 1125px)","(max-height: 1125px)","(min-height: 1062.5px)","(max-height: 1062.5px)","(pointer: none)","(pointer: coarse)","(pointer: fine)","(width = 0px)","(width = 8000px)","(width > 8000px)","(width < 0px)","(min-width: 4000px)","(max-width: 4000px)","(min-width: 2000px)","(max-width: 2000px)","(min-width: 1000px)","(max-width: 1000px)","(min-width: 1500px)","(max-width: 1500px)","(min-width: 1750px)","(max-width: 1750px)","(min-width: 1875px)","(max-width: 1875px)","(min-width: 1937.5px)","(max-width: 1937.5px)","(prefers-color-scheme: light)","(prefers-color-scheme: dark)","(inverted-colors: none)","(inverted-colors: inverted)","(aspect-ratio = 0.25)","(aspect-ratio = 4)","(aspect-ratio > 4)","(aspect-ratio < 0.25)","(min-aspect-ratio: 2.125)","(max-aspect-ratio: 2.125)","(prefers-reduced-transparency: no-preference)","(prefers-reduced-transparency: reduce)"]) take('matchMedia ' + q, () => matchMedia(q).matches);

    // The element type is not in the log -- the key names the interface, and
    // both <audio> and <video> reach HTMLMediaElement -- so ask the one the
    // MIME's top-level type names.
    for (const m of ["audio/mpeg;","video/mpeg;","audio/wave; codecs=1","video/mp4; codecs=\"avc1.64001E, mp4a.40.2\"","video/mp4; codecs=bogus","video/x-matroska; codecs=\"theora, vorbis\"","video/x-mpeg","video/ogg; codecs=speex","audio/webm;","video/ogg; codecs=\"theora, speex\"","video/mp4; codecs=\"avc1.42E01E\"","audio/ogg; codecs=\"vorbis\"","audio/wav; codecs=\"0\"","video/mp4;","audio/wav; codecs=\"1\"","audio/wav; codecs=\"2\"","video/mp2t; codecs=\"avc1.42E01E,mp4a.40.2\"","audio/aac;","video/mp4; codecs=mp4a.40.2","video/ogg; codecs=\"theora\"","audio/wave;","video/webm; codecs=\"vp8, vorbis\"","audio/wav;","video/mp4; codecs=\"mp4v.20.240, mp4a.40.2\"","audio/x-mpegurl","video/3gpp; codecs=\"mp4v.20.8, samr\"","audio/x-m4a;","video/mp4; codecs=\"mp4v.20.8, mp4a.40.2\"","video/ogg; codecs=opus","audio/wave; codecs=2","audio/wave; codecs=0","video/mp4; codecs=\"avc1.42c00d\"","video/webm; codecs=vorbis","video/webm; codecs=\"vorbis,vp9\"","audio/mp4; codecs=\"mp4a.40.2\"","audio/x-mpeg"]) {
        take('canPlayType ' + m, () => document.createElement(m.startsWith('audio') ? 'audio' : 'video').canPlayType(m));
    }

    for (const m of ["video/webm","audio/webm","video/webm;codecs=vp8","video/webm;codecs=daala","video/webm;codecs=h264","audio/webm;codecs=opus","video/mp4","video/mp4;codecs=avc1.64003E,mp4a.40.2","video/mp4;codecs=avc1.64003E,opus","video/mp4;codecs=avc3.64003E,mp4a.40.2","video/mp4;codecs=avc3.64003E,opus","video/mp4;codecs=hvc1.1.6.L186.B0,mp4a.40.2","video/mp4;codecs=hvc1.1.6.L186.B0,opus","video/mp4;codecs=hev1.1.6.L186.B0,mp4a.40.2","video/mp4;codecs=hev1.1.6.L186.B0,opus","video/mp4;codecs=av01.0.19M.08,mp4a.40.2","video/mp4;codecs=av01.0.19M.08,opus"]) {
        take('isTypeSupported ' + m, () => (typeof MediaRecorder === 'undefined' ? 'no-MediaRecorder' : MediaRecorder.isTypeSupported(m)));
    }

    // The whole IANA image registry. The answer that matters is the type the
    // data URL comes back as, not the pixels: Chrome falls back to image/png
    // for everything it cannot encode, so the reading is which handful it can.
    {
        const canvas = document.createElement('canvas');
        canvas.width = 20;
        canvas.height = 20;
        const ctx = canvas.getContext('2d');
        if (ctx) {
            ctx.fillStyle = '#4285f4';
            ctx.fillRect(2, 2, 16, 16);
        }
        for (const t of ["image/png","image/jpeg","image/jpg","image/webp","image/bmp","image/x-png","image/gif","image/aces","image/apng","image/avci","image/avcs","image/avif","image/cgm","image/dicom-rle","image/dpx","image/emf","image/example","image/fits","image/g3fax","image/heic","image/heic-sequence","image/heif","image/heif-sequence","image/hej2k","image/hsj2","image/j2c","image/jls","image/jp2","image/jph","image/jphc","image/jpm","image/jpx","image/jxr","image/jxrA","image/jxrS","image/jxs","image/jxsc","image/jxsi","image/jxss","image/ktx","image/ktx2","image/naplps","image/prs.btif","image/prs.pti","image/pwg-raster","image/svg+xml","image/t38","image/tiff","image/tiff-fx","image/vnd.adobe.photoshop","image/vnd.airzip.accelerator.azv","image/vnd.cns.inf2","image/vnd.dece.graphic","image/vnd.djvu","image/vnd.dwg","image/vnd.dxf","image/vnd.dvb.subtitle","image/vnd.fastbidsheet","image/vnd.fpx","image/vnd.fst","image/vnd.fujixerox.edmics-mmr","image/vnd.fujixerox.edmics-rlc","image/vnd.globalgraphics.pgb","image/vnd.microsoft.icon","image/vnd.mix","image/vnd.ms-modi","image/vnd.mozilla.apng","image/vnd.net-fpx","image/vnd.pco.b16","image/vnd.radiance","image/vnd.sealed.png","image/vnd.sealedmedia.softseal.gif","image/vnd.sealedmedia.softseal.jpg","image/vnd.svf","image/vnd.tencent.tap","image/vnd.valve.source.texture","image/vnd.wap.wbmp","image/vnd.xiff","image/vnd.zbrush.pcx","image/wmf"]) {
            take('toDataURL ' + t, () => {
                const url = canvas.toDataURL(t);
                const semi = url.indexOf(';');
                return semi === -1 ? url.slice(0, 32) : url.slice(0, semi);
            });
        }
    }

    for (const [version, enums] of [['webgl', [37446]], ['webgl2', [37445,37446,33902,7938,35377,35375,33901,35379,36349,35374]]]) {
        const gl = document.createElement('canvas').getContext(version);
        for (const e of enums) {
            take(version + '.getParameter ' + e, () => {
                if (!gl) return 'no-context';
                const v = gl.getParameter(e);
                return v && v.constructor && v.constructor.name !== 'String' && typeof v === 'object'
                    ? v.constructor.name + ':' + Array.from(v).join(',')
                    : v;
            });
        }
        // Both arms were seen asking for this one before every getParameter,
        // and its absence is what turns 37446 into the driver's own string.
        take(version + '.WEBGL_debug_renderer_info', () => (gl ? !!gl.getExtension('WEBGL_debug_renderer_info') : 'no-context'));
    }

    // Not the tag, the interface behind it: 'invalidTag' has to land on
    // HTMLUnknownElement and 'math' on MathMLElement, and an engine that maps
    // every unknown name to HTMLElement says so here.
    for (const t of ["div","iframe","input","canvas","template","p","span","math","audio","video","invalidTag"]) {
        take('createElement ' + t, () => Object.prototype.toString.call(document.createElement(t)));
    }
    for (const t of ["TouchEvent","Event"]) {
        take('createEvent ' + t, () => Object.prototype.toString.call(document.createEvent(t)));
    }

    // Read off <body> rather than the element the page used: the point is
    // whether the property resolves at all and in what notation, not the site's
    // stylesheet.
    for (const p of ["font-size","height","font-family","color"]) {
        take('getPropertyValue ' + p, () => getComputedStyle(document.body).getPropertyValue(p));
    }

    return JSON.stringify(out);
})()
