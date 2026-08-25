(function () {
    // A 496239-char one-byte string, the size the guard hashes (its own source).
    var parts = [];
    for (var i = 0; i < 496239 / 62; i++) parts.push('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
    var s = parts.join('').slice(0, 496239);
    var t0 = performance.now();
    var acc = 0, idx = 1;
    for (var k = 0; k < 650000; k++) { idx = (idx * 1103515245 + 12345) & 0x7fffffff; acc += s.charCodeAt(idx % 496239); }
    var randomAccess = performance.now() - t0;
    t0 = performance.now();
    for (var j = 0; j < 650000; j++) acc += s.charCodeAt(j % 496239);
    var linear = performance.now() - t0;
    // Building a long string a character at a time, the other half of that loop.
    t0 = performance.now();
    var out = '';
    for (var m = 0; m < 200000; m++) out += String.fromCharCode(65 + (m & 15));
    var concatMs = performance.now() - t0;
    return { len: s.length, randomAccessMs: Math.round(randomAccess), linearMs: Math.round(linear), concat200kMs: Math.round(concatMs), acc: acc, outLen: out.length };
})()
