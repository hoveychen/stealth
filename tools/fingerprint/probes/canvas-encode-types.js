// What a canvas will encode to, and how it reads the two arguments that decide
// it. This is the ground truth behind canvas/encode.zig, canvas/jpeg.zig and
// canvas/webp.zig.
//
// Kasada walks the whole IANA image registry through toDataURL on x-hyatt (see
// kasada-argument-answers.js) and reads back which handful of types come back
// as themselves. That list is three long on Chrome, and the reading is the type
// string -- so the rows to compare here are the mime and roundtrip ones.
//
// Two groups of rows are expected to differ and are here to be read, not
// compared:
//
//   bytes ...      -- our PNG does not chase libpng's row filters, our JPEG
//                     does not chase libjpeg-turbo's DCT, and our WebP is
//                     lossless VP8L where Chrome writes a lossy VP8 keyframe
//                     below quality 1.0. Each encoder says so at the top.
//   roundtrip ...  -- Chrome-only ground truth. Reading an encoder's output
//                     back means decoding it, and an <img> pointed at a data
//                     URL stays 0x0 in this engine -- for its *own* PNG as
//                     much as for a JPEG, so this measures the image decoding
//                     path and not the encoders. What it pins down is what
//                     Chrome does with alpha: PNG and WebP keep it, JPEG
//                     composites onto black. The engine's own pixels were
//                     checked against an external decoder instead.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/canvas-encode-types.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/canvas-encode-types.js --url https://example.com/
(async () => {
    const out = {};
    const take = async (key, fn) => {
        try {
            out[key] = await fn();
        } catch (e) {
            out[key] = 'threw:' + (e && e.name);
        }
    };

    // A drawing with three kinds of pixel in it: opaque, half-transparent and
    // never touched. JPEG has to do something with the last two, and what it
    // does is the measurement.
    const canvas = document.createElement('canvas');
    canvas.width = 20;
    canvas.height = 20;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = 'rgba(66,133,244,1)';
    ctx.fillRect(2, 2, 16, 16);
    ctx.fillStyle = 'rgba(255,0,0,0.5)';
    ctx.fillRect(0, 0, 4, 4);

    const mime = (...args) => {
        const url = canvas.toDataURL(...args);
        const semi = url.indexOf(';');
        return semi === -1 ? url : url.slice(0, semi);
    };
    const bytes = (...args) => {
        const url = canvas.toDataURL(...args);
        const comma = url.indexOf(',');
        return comma === -1 ? 0 : atob(url.slice(comma + 1)).length;
    };

    // The registry, plus the near misses that say how the match is made: the
    // whole string, ASCII case-insensitively, with no parameter parsing and no
    // trimming.
    for (const t of ['image/png', 'image/jpeg', 'image/webp', 'image/jpg', 'image/x-png',
        'image/gif', 'image/bmp', 'image/apng', 'image/avif', 'image/svg+xml', 'image/tiff',
        'image/jxr', 'image/vnd.mozilla.apng', 'image/vnd.sealedmedia.softseal.jpg',
        'IMAGE/JPEG', 'Image/WebP', ' image/jpeg', 'image/jpeg ', 'image/jpeg;', 'image/jpeg;q=1',
        'image/webp;', 'jpeg', '', 'image/bogus']) {
        await take('mime ' + JSON.stringify(t), () => mime(t));
    }
    await take('mime undefined', () => mime());
    await take('mime null', () => mime(null));

    // Quality is declared `any`, so only a real number inside [0, 1] counts.
    // The readings that must agree are which arguments are *listened to*, which
    // shows up as whether the size moves off the default at all.
    const fallback = bytes('image/jpeg');
    for (const q of [0, 0.1, 0.5, 0.92, 1]) {
        await take('jpeg quality ' + q + ' differs from default', () => bytes('image/jpeg', q) !== fallback);
    }
    for (const q of [undefined, -1, 2, NaN, 'x', null, true]) {
        await take('jpeg quality ' + String(q) + ' is the default', () => bytes('image/jpeg', q) === fallback);
    }
    await take('png ignores quality', () => bytes('image/png', 0) === bytes('image/png'));
    await take('jpeg 0 is smaller than 1', () => bytes('image/jpeg', 0) < bytes('image/jpeg', 1));

    // What each encoder does with the alpha channel, read back through the
    // browser's own decoder. PNG and WebP keep it; JPEG has nowhere to put it
    // and composites onto black, which is why the half-red corner comes back
    // near 127 and the untouched corner comes back near 0.
    const roundTrip = (url) => new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => {
            const target = document.createElement('canvas');
            target.width = 20;
            target.height = 20;
            const tctx = target.getContext('2d');
            tctx.clearRect(0, 0, 20, 20);
            tctx.drawImage(img, 0, 0);
            // Bucketed to the nearest 16, so the two arms agree wherever they
            // only disagree by an encoder's own rounding.
            const at = (x, y) => Array.from(tctx.getImageData(x, y, 1, 1).data)
                .map((v) => Math.round(v / 16) * 16).join(',');
            resolve([img.width + 'x' + img.height, at(10, 10), at(1, 1), at(19, 19)].join(' '));
        };
        img.onerror = () => reject(new Error('decode'));
        img.src = url;
    });

    for (const t of ['image/png', 'image/jpeg', 'image/webp']) {
        await take('roundtrip ' + t, () => roundTrip(canvas.toDataURL(t)));
    }

    // toBlob and OffscreenCanvas.convertToBlob read the type the same way.
    const blobType = (t) => new Promise((resolve) => {
        canvas.toBlob((blob) => resolve(blob === null ? 'null' : blob.type), t);
    });
    for (const t of [undefined, 'image/png', 'image/jpeg', 'image/webp', 'IMAGE/JPEG', 'image/jpg', 'image/bogus']) {
        await take('toBlob ' + String(t), () => blobType(t));
    }

    const offscreen = new OffscreenCanvas(20, 20);
    const octx = offscreen.getContext('2d');
    octx.fillStyle = '#4285f4';
    octx.fillRect(2, 2, 16, 16);
    for (const options of [undefined, {}, { type: 'image/jpeg' }, { type: 'image/webp' },
        { type: 'IMAGE/JPEG' }, { type: 'image/jpg' }, { type: 'image/bogus' }]) {
        await take('convertToBlob ' + JSON.stringify(options ?? null), async () => (await offscreen.convertToBlob(options)).type);
    }
    await take('convertToBlob quality is read', async () => {
        const lossy = await offscreen.convertToBlob({ type: 'image/jpeg', quality: 0 });
        const better = await offscreen.convertToBlob({ type: 'image/jpeg' });
        return lossy.size < better.size;
    });

    // A canvas with no area has no image, whatever was asked for.
    const degenerate = document.createElement('canvas');
    degenerate.width = 0;
    for (const t of [undefined, 'image/jpeg', 'image/webp']) {
        await take('zero area ' + String(t), () => degenerate.toDataURL(t));
    }

    // Read, not compared -- see the header.
    for (const t of ['image/png', 'image/jpeg', 'image/webp']) {
        await take('bytes ' + t, () => bytes(t));
    }

    return JSON.stringify(out);
})()
