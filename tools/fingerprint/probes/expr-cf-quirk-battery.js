// The engine-behaviour battery Cloudflare's guard runs, transcribed from the
// disassembled bytecode (pc 76400-84400 of the /fo/ program; see the README
// section "Naming all 48 handlers" and scratch/cfvm/main.disasm.txt).
//
// The guard pushes each of these results into one array and stores it under the
// key `OjmeV1`. Unlike every collection surface already exhausted, these are
// answers only the *engine* can give -- so a mismatch here is an engine defect,
// not a value we could choose to report differently.
//
// Each entry is [name, () => value]. Anything that throws is reported as
// "throw:<message>" rather than aborting the run, because a missing API is
// itself one of the readings.
(() => {
    const D = document;
    const el = (t) => D.createElement(t);
    const body = D.body || D.documentElement;
    const head = D.head || D.documentElement;

    const probes = [
        // --- the JS-quirk half ------------------------------------------
        ['wat-batman', () => Array(16).join('wat' - 1) + ' Batman!'],
        ['banana', () => 'b' + 'a' + +'a' + 'a'],
        ['foo-nan', () => 'foo' + + 'bar'],
        ['parseInt-0.0000005', () => String(parseInt(0.0000005))],
        ['str-5e-7', () => String(5e-7)],
        ['str-5e25', () => String(5e25)],
        ['parseInt-Infinity', () => String(parseInt('Infinity', 10))],
        ['parseInt-Infinity-val', () => String(parseInt(Infinity))],
        ['1e16-plus-1', () => (10000000000000000 + 1) === 10000000000000002],
        ['point-three', () => (0.1 + 0.2) === 0.3],
        ['arr-plus-arr', () => String([] + [])],
        ['arr-plus-obj', () => String([] + {})],
        ['obj-to-string', () => String({})],
        ['bang-false-str', () => !!'false' === !!'true'],
        ['neg-infinity', () => String(-Infinity)],
        ['toString-undef', () => Object.prototype.toString.call(undefined)],
        ['this-boxing', () => {
            // eslint-disable-next-line no-eval
            return eval('(function(){return this}.call(1)) !== (function(){return this}.call(1))');
        }],
        ['eval-tostring-counter', () => {
            // eslint-disable-next-line no-eval
            const a = eval('0, { i: 1, toString: function(){return this.i++;}}');
            return String(a) + '/' + String(a) + '/' + String(a);
        }],
        ['typeof-module', () => { try { return eval('typeof module'); } catch (e) { return 'throw'; } }],
        ['typeof-global', () => { try { return eval('typeof global'); } catch (e) { return 'throw'; } }],
        ['typeof-pyimport', () => { try { return eval('typeof pyimport'); } catch (e) { return 'throw'; } }],

        // --- coercion and parseInt radix family ------------------------
        ['document-all-typeof', () => typeof D.all],
        ['document-all-is-object', () => String(D.all instanceof Object)],
        ['number-undefined', () => String(Number(undefined))],
        ['parseint-fv-16', () => String(parseInt('f*v', 16))],
        ['parseint-inf-radix', () => [10, 18, 19, 23, 24, 29, 30]
            .map((r) => String(parseInt('Infinity', r))).join(',')],
        ['parseint-null-24', () => String(parseInt(null, 24))],
        ['parseint-null-23', () => String(parseInt(null, 23))],
        ['parseint-06', () => String(parseInt('06'))],
        ['math-max-empty', () => String(Math.max())],
        ['math-min-empty', () => String(Math.min())],
        ['mod-3.14-5', () => String(3.14 % 5)],
        ['mod-13.14-3.14', () => String(13.14 % 3.14)],
        ['nested-arr-eq-str', () => String([[[[[[]]]]]] == '')],
        ['nested-arr-length', () => { const a = [[[[[[]]]]]]; a[0][0][0].length = 3; return String(a == ''); }],
        ['arr-null-eq-0', () => String([null] == 0)],
        ['arr-undef-eq-0', () => String([undefined] == 0)],
        ['arr-arr-eq-0', () => String([[]] == 0)],
        ['arr-empty-eq-str', () => String([''] == '')],
        ['banana-slice', () => ('b' + 'a' + +'a' + 'a').toLowerCase().slice(2, 5)],
        ['nan-tolowercase', () => { try { return String(NaN).toLowerCase(); } catch (e) { return 'throw'; } }],
        ['navigator-proto-plugins', () => 'plugins' in Object.getPrototypeOf(navigator) ? 'proto' : 'own'],

        // --- the DOM half ----------------------------------------------
        ['comment-innerhtml-roundtrip', () => {
            const a = el('p'), b = el('p');
            a.appendChild(D.createComment('-->--<!--'));
            b.innerHTML = a.innerHTML;
            return a.innerHTML === b.innerHTML;
        }],
        ['comment-innertext-roundtrip', () => {
            const a = el('p'), b = el('p');
            a.appendChild(D.createComment('-->--<!--'));
            b.innerHTML = a.innerHTML;
            return String(b.innerText) === String(a.innerText);
        }],
        ['input-maxlength', () => String(el('input').maxLength)],
        ['textarea-maxlength', () => String(el('textarea').maxLength)],
        ['stylesheet-applies', () => {
            const d = el('div');
            d.className = 'YYXc3';
            body.appendChild(d);
            const s = el('style');
            s.innerText = '.YYXc3 { display: flex; }';
            head.appendChild(s);
            const got = getComputedStyle(d).display;
            s.remove(); d.remove();
            return got === 'flex';
        }],
        ['scrollintoview-type', () => typeof el('div').scrollIntoView],
        ['getrootnode-composed-array', () => {
            const host = el('div'), span = el('span');
            const root = host.attachShadow({ mode: 'open' });
            root.appendChild(span);
            // `composed: []` -- the guard passes an array, not a boolean
            return span.getRootNode({ composed: [] }) === D ? 'document' : 'shadow';
        }],
        ['domparser-p-recovery', () => {
            const p = new DOMParser().parseFromString('<p>EnIF0</div><p>ikyR0</p>', 'text/html');
            return p.body.innerHTML;
        }],
        ['domparser-attr-entity', () => {
            const p = new DOMParser().parseFromString('<div data-foo="&#34;"></div>', 'text/html');
            return p.body.innerHTML;
        }],
        ['listener-options-array', () => {
            // The third argument is an array, and `bubbles` is an array too:
            // both have to survive WebIDL coercion the way Chrome does it.
            const d = el('div');
            let a = 0, b = 0;
            const fa = () => { a++; }, fb = () => { b++; };
            d.addEventListener('x', fa, []);
            d.addEventListener('x', fb, []);
            d.removeEventListener('x', fa, []);
            d.dispatchEvent(new Event('x', { bubbles: [] }));
            return a + '/' + b;
        }],
        ['xhr-readystate-constants', () => {
            const x = new XMLHttpRequest();
            return [x.UNSENT, x.OPENED, x.HEADERS_RECEIVED, x.LOADING, x.DONE].join(',');
        }],
        ['div-translate', () => String(el('div').translate)],
        ['div-draggable', () => String(el('div').draggable)],
        ['div-spellcheck-type', () => typeof el('div').spellcheck],
        ['input-dirname', () => JSON.stringify(el('input').dirName)],
        ['textarea-dirname', () => JSON.stringify(el('textarea').dirName)],
        ['option-defaultselected', () => String(el('option').defaultSelected)],
        ['option-label', () => JSON.stringify(el('option').label)],
        ['select-via-innerhtml', () => {
            const d = el('div');
            d.innerHTML = '<select><option selected value="ZgaQ3">ZgaQ3</option>' +
                '<option value="Saymo2">Saymo2</option></select>';
            const s = d.firstChild;
            return [String(s.options[0].selected), typeof s.selectedIndex, typeof s.value].join(',');
        }],
        ['range-mousedown-buttons', () => {
            const i = el('input');
            i.type = 'range';
            let fired = 0;
            i.addEventListener('mousedown', (e) => { fired = e.buttons; });
            i.dispatchEvent(new MouseEvent('mousedown', { buttons: 1 }));
            return String(fired);
        }],
        ['structuredclone-bigint-object', () => String(structuredClone(Object(BigInt(611))).toString())],
        ['structuredclone-regexp', () => String(structuredClone(/gule/).toString())],
    ];

    const out = {};
    for (const [name, fn] of probes) {
        try { out[name] = fn(); } catch (e) { out[name] = 'throw:' + (e && e.message ? e.message : String(e)); }
    }
    return out;
})()
