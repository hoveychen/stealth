// The shape of the loop that costs Chrome 650ms and this engine 14ms.
//
// Coverage of the macys challenge script's first pass puts 5896530 executions on
// the one-character body of `while(!hTh.czh());` inside
//
//     function MOm(WLh, pDh) {
//         var hTh = { WLh: WLh, Phh: pDh, nzh: 0, Gdh: 0, czh: DTh };
//         while (!hTh.czh());
//         return hTh['Phh'] >>> 0;
//     }
//
// -- a hash over a 496239-character string driven by a state machine that
// reassigns `this.czh` to the next step every iteration, about twelve steps per
// character. This reproduces that shape and nothing else, so the two engines can
// be compared on it directly.
(function () {
    var parts = [];
    for (var i = 0; i < 496239 / 62; i++) parts.push('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
    var s = parts.join('').slice(0, 496239);

    function s0() { this.c = s1; this.acc = (this.acc ^ this.src.charCodeAt(this.i)) >>> 0; }
    function s1() { this.c = s2; this.acc = (this.acc + ((this.acc << 1) >>> 0)) >>> 0; }
    function s2() { this.c = s3; this.tmp = this.acc & 0xff; }
    function s3() { this.c = s4; this.acc = (this.acc ^ (this.tmp << 7)) >>> 0; }
    function s4() { this.c = s5; this.acc = (this.acc * 16777619) >>> 0; }
    function s5() { this.c = s6; this.tmp = (this.acc >>> 13); }
    function s6() { this.c = s7; this.acc = (this.acc ^ this.tmp) >>> 0; }
    function s7() { this.c = s8; this.acc = (this.acc + this.i) >>> 0; }
    function s8() { this.c = s9; this.tmp = this.src.length; }
    function s9() { this.c = s10; this.acc = (this.acc ^ (this.tmp & 0xffff)) >>> 0; }
    function s10() { this.c = s11; this.acc = (this.acc << 3 | this.acc >>> 29) >>> 0; }
    function s11() { this.i++; this.c = s0; return this.i >= this.src.length; }

    var t = performance.now();
    var st = { src: s, acc: 2166136261, i: 0, tmp: 0, c: s0 };
    var steps = 0;
    while (!st.c()) steps++;
    var ms = performance.now() - t;
    return { chars: s.length, steps: steps, ms: Math.round(ms), hash: st.acc >>> 0 };
})()
