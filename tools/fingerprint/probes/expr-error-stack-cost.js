(function () {
    var t0 = performance.now();
    var n = 20000, sink = 0;
    for (var i = 0; i < n; i++) { var e = new Error('x'); sink += e.stack ? e.stack.length : 0; }
    var mk = performance.now() - t0;
    t0 = performance.now();
    for (var j = 0; j < n; j++) { try { null.x; } catch (e2) { sink += e2.stack ? e2.stack.length : 0; } }
    var thrown = performance.now() - t0;
    t0 = performance.now();
    var s2 = 0;
    for (var k = 0; k < n; k++) { var e3 = new Error('y'); s2 += e3.message.length; }
    var noStack = performance.now() - t0;
    return { n: n, newErrorStackMs: Math.round(mk), thrownStackMs: Math.round(thrown), newErrorNoStackMs: Math.round(noStack), stackLen: (new Error('z')).stack.length, sink: sink };
})()
