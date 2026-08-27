// Is the text-advance grid 1/128, or is it 1/64 divided by the device pixel
// ratio?
//
// Every headed-Chrome reading in `expr-b81-grid-128.js` is a multiple of 1/128
// and 4 of 12 are not multiples of 1/64, which reads as a 1/128 grid. But this
// host's display is 2x, and 1/128 is exactly 1/64 over 2 -- so a grid that is
// really "1/64 of a device pixel" would look identical here and would be 1/64
// on a 1x display. Which one it is decides what this engine should answer,
// because the engine's own `devicePixelRatio` is what a page sees.
//
// The ratio is reported next to the readings so the two cannot be confused,
// and `zoom` is used to move the ratio without a second machine: Chrome scales
// the effective device scale factor by the page zoom, so a 0.5 zoom on a 2x
// display puts the text on a 1x footing while leaving CSS pixels alone.
(() => {
    const out = {};
    out['dpr'] = String(window.devicePixelRatio);
    out['screen'] = window.screen.width + 'x' + window.screen.height;

    const host = document.createElement('div');
    document.documentElement.appendChild(host);
    const ctx = document.createElement('canvas').getContext('2d');

    const read = (key, font, text) => {
        host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font:' + font);
        host.textContent = text;
        ctx.font = font;
        out[key + '.rect'] = String(host.getBoundingClientRect().width);
        out[key + '.measure'] = String(ctx.measureText(text).width);
        out[key + '.dpr'] = String(window.devicePixelRatio);
    };

    // The three cases that separate the grids: at 13px one `a` quantises by
    // 1/512, and 16px `aaa` is a 1/128 multiple that is not a 1/64 one.
    const cases = () => {
        read('a13', '13px serif', 'a');
        read('aaa13', '13px serif', 'aaa');
        read('aaa16', '16px serif', 'aaa');
        read('sweep13', '13px serif', 'aaa bbb ccc');
    };
    cases();

    // Same four at half zoom, which halves the effective device scale factor.
    const prefix = 'zoom50.';
    document.documentElement.style.zoom = '0.5';
    const saved = {};
    read(prefix + 'a13', '13px serif', 'a');
    read(prefix + 'aaa13', '13px serif', 'aaa');
    read(prefix + 'aaa16', '16px serif', 'aaa');
    read(prefix + 'sweep13', '13px serif', 'aaa bbb ccc');
    document.documentElement.style.zoom = '';
    void saved;

    host.remove();
    return out;
})();
