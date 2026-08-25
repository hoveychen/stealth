// Does a first call into a large script cost what Chrome's numbers imply?
//
// Akamai's sensor reports 645-786 on a cold Chrome and 5 on the same browser's
// second pass, against 14-22 here -- one-time work, inside the JS frame, that no
// wrapped API accounts for. V8 compiles a function's body on first call, so a
// 578KB script's first pass pays for every inner function it reaches. This
// builds a script of that size out of distinct functions and separates the four
// costs: compiling the outer script, running it (which only *declares* the
// inner functions), calling each one once, and calling them again.
(function () {
    var parts = [];
    var count = 3000;
    for (var i = 0; i < count; i++) {
        parts.push('function f' + i + '(a){var x' + i + '=a*' + (i + 3) + ';var y=' + i +
            ';for(var j=0;j<3;j++){y=(y*31+x' + i + '+j)&65535;if(y>' + (i % 100) +
            '){y-=' + (i % 7 + 1) + ';}else{y+=' + (i % 11 + 1) + ';}}var s="k' + i +
            '"+y;return s.length+y;}');
    }
    parts.push('return [' + Array.from({ length: count }, function (_, k) { return 'f' + k; }).join(',') + '];');
    var src = parts.join('\n');

    var t = performance.now();
    var outer = new Function(src);
    var compileMs = performance.now() - t;

    t = performance.now();
    var fns = outer();
    var declareMs = performance.now() - t;

    t = performance.now();
    var acc = 0;
    for (var a = 0; a < fns.length; a++) acc += fns[a](a);
    var firstCallMs = performance.now() - t;

    t = performance.now();
    for (var b = 0; b < fns.length; b++) acc += fns[b](b);
    var secondCallMs = performance.now() - t;

    return {
        bytes: src.length, functions: count, acc: acc,
        compileMs: Math.round(compileMs), declareMs: Math.round(declareMs),
        firstCallMs: Math.round(firstCallMs), secondCallMs: Math.round(secondCallMs),
    };
})()
