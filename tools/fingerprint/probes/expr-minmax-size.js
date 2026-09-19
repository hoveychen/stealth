// What `min-width` / `max-width` / `min-height` / `max-height` compute to, and
// what they do to the used width and height.
//
// Two questions in one table. A percentage min/max is not resolved at
// computed-value time -- it is a share of a containing block the layout has to
// find -- so Chrome reports it as written, the way it does `top` and
// `text-indent`; a length is resolved like any other. And whichever the
// declaration is, the BOUND is applied, so the reported `width` is the clamped
// one.
//
// Read in a 400x200 block. Backs src/browser/tests/css/computed_minmax_size.html.
(() => {
    const host = document.createElement('div');
    host.setAttribute('style', 'width:400px; height:200px; font-size:16px');
    document.body.appendChild(host);
    const NAMES = ['min-width', 'max-width', 'min-height', 'max-height', 'width', 'height'];
    const out = {};
    const read = (label, css) => {
        const el = document.createElement('div');
        el.setAttribute('style', css);
        el.textContent = 'x';
        host.appendChild(el);
        const cs = getComputedStyle(el);
        out[label] = NAMES.map((n) => cs.getPropertyValue(n)).join(' | ');
        el.remove();
    };
    read('bare', '');
    read('pxBounds', 'min-width:50px; max-width:120px; min-height:10px; max-height:40px');
    read('pctBounds', 'min-width:25%; max-width:60%; min-height:10%; max-height:80%');
    read('emBounds', 'min-width:3em; max-width:10em; min-height:2em; max-height:4em');
    read('calcBounds', 'min-width:calc(10% + 10px); max-width:calc(50% - 4px)');
    read('maxWidthClamps', 'width:300px; max-width:100px; height:50px');
    read('minWidthClamps', 'width:50px; min-width:200px; height:50px');
    read('maxWidthPctClamps', 'width:300px; max-width:25%; height:50px');
    read('minWidthPctClamps', 'width:50px; min-width:75%; height:50px');
    read('maxHeightClamps', 'width:50px; height:300px; max-height:100px');
    read('minHeightClamps', 'width:50px; height:20px; min-height:120px');
    read('maxWidthNoneKeyword', 'width:300px; max-width:none');
    read('minWidthAutoKeyword', 'width:300px; min-width:auto');
    read('maxBeatsMin', 'width:300px; min-width:250px; max-width:100px');
    read('autoWidthMaxWidth', 'max-width:100px; height:50px');
    read('autoWidthMinWidth', 'min-width:600px; height:50px');
    read('noneBounds', 'display:none; min-width:25%; max-width:60%; min-height:10%; width:50%');
    out.viewport = [window.innerWidth, window.innerHeight];
    host.remove();
    return out;
})()
