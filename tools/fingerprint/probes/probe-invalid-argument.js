// `error.InvalidArgument` in this engine maps to the literal string "invalid
// argument", which no browser says. Blink's wording is per-parameter and per
// failure kind, and this walks every kind the bridge can hit so the shape is
// measured rather than derived from one example:
//
//   * a dictionary parameter given a non-object
//   * a sequence / record parameter given something not iterable
//   * an enum-valued dictionary member given a value outside the enum
//   * an interface parameter given the wrong brand
//   * the same failures at parameter 2, to see whether the index is named
//   * the same failures on an operation rather than a constructor, to see the
//     "Failed to execute 'x' on 'Y'" lead-in
//
// Run through run-probe.mjs against a real http page, not about:blank -- some of
// these need a document and a storage area, and an opaque origin changes both.
(() => {
    const raised = (fn) => {
        try {
            fn();
            return { throws: false };
        } catch (e) {
            return { throws: true, name: e?.name ?? String(e), message: e?.message ?? '' };
        }
    };
    const out = {};
    const at = (label, fn) => { out[label] = raised(fn); };

    // --- dictionary parameter, non-object ---------------------------------
    at("new Blob([], 1)", () => new Blob([], 1));
    at("new AudioContext(1)", () => new AudioContext(1));
    at("new CSSStyleSheet(1)", () => new CSSStyleSheet(1));
    at("new DocumentTimeline(1)", () => new DocumentTimeline(1));
    at("new TaskController(1)", () => new TaskController(1));
    at("new RTCIceCandidate('nope')", () => new RTCIceCandidate('nope'));
    at("new RTCIceCandidate(1)", () => new RTCIceCandidate(1));
    at("new DOMQuad(1)", () => new DOMQuad(1));
    at("new EventSource('/x', 1)", () => new EventSource('/x', 1));

    // --- dictionary at parameter 2 ---------------------------------------
    at("new IntersectionObserver(fn, 1)", () => new IntersectionObserver(() => {}, 1));
    at("new MutationObserver(fn) then observe(el, 1)", () => {
        new MutationObserver(() => {}).observe(document.body, 1);
    });
    at("el.addEventListener('x', fn, 1)", () => document.body.addEventListener('x', () => {}, 1));

    // --- sequence / record parameter --------------------------------------
    at("new Blob(1)", () => new Blob(1));
    at("new Headers(1)", () => new Headers(1));
    at("new Headers('nope')", () => new Headers('nope'));
    at("new CSSTransformValue(1)", () => new CSSTransformValue(1));
    at("new CSSUnparsedValue(1)", () => new CSSUnparsedValue(1));
    at("new URLSearchParams(1)", () => new URLSearchParams(1));

    // --- enum-valued dictionary member ------------------------------------
    at("new Request(url, {cache:'nope'})", () => new Request('http://x.test/', { cache: 'nope' }));
    at("new Request(url, {credentials:'nope'})", () => new Request('http://x.test/', { credentials: 'nope' }));
    at("new Request(url, {redirect:'nope'})", () => new Request('http://x.test/', { redirect: 'nope' }));
    at("new Request(url, {priority:'nope'})", () => new Request('http://x.test/', { priority: 'nope' }));
    at("new Request(url, {mode:'nope'})", () => new Request('http://x.test/', { mode: 'nope' }));
    at("new Response('x', {status:99})", () => new Response('x', { status: 99 }));
    at("el.attachShadow({mode:'nope'})", () => document.body.attachShadow({ mode: 'nope' }));
    at("el.scrollIntoView({behavior:'nope'})", () => document.body.scrollIntoView({ behavior: 'nope' }));

    // --- enum as a bare parameter (not a dictionary member) ---------------
    at("el.insertAdjacentHTML('nope', 'x')", () => document.body.insertAdjacentHTML('nope', 'x'));
    at("document.createNodeIterator(el, 1, 1)", () => document.createNodeIterator(document.body, 1, 1));

    // --- interface parameter, wrong brand ---------------------------------
    at("new Animation(1)", () => new Animation(1));
    at("new FormData(1)", () => new FormData(1));
    at("new KeyframeEffect(1, null)", () => new KeyframeEffect(1, null));
    at("el.appendChild(1)", () => document.body.appendChild(1));
    at("el.insertBefore(1, null)", () => document.body.insertBefore(1, null));
    at("el.removeChild(1)", () => document.body.removeChild(1));
    at("new CSSRotate(1)", () => new CSSRotate(1));
    at("new CSSSkewX(1)", () => new CSSSkewX(1));

    // --- operations rather than constructors ------------------------------
    at("crypto.getRandomValues(1)", () => crypto.getRandomValues(1));
    at("crypto.getRandomValues([])", () => crypto.getRandomValues([]));
    at("document.createElement()", () => document.createElement());
    at("el.setAttribute('x')", () => document.body.setAttribute('x'));
    at("el.matches()", () => document.body.matches());
    at("el.closest()", () => document.body.closest());
    at("document.querySelector()", () => document.querySelector());
    at("el.animate(1)", () => document.body.animate(1));
    at("fetch(1)", () => fetch(1));
    at("new URL()", () => new URL());
    at("history.pushState()", () => history.pushState());
    at("localStorage.setItem('k')", () => localStorage.setItem('k'));

    // --- a callback parameter given a non-callable ------------------------
    at("new MutationObserver(1)", () => new MutationObserver(1));
    at("new IntersectionObserver(1)", () => new IntersectionObserver(1));
    at("new PerformanceObserver(1)", () => new PerformanceObserver(1));
    at("new ResizeObserver(1)", () => new ResizeObserver(1));
    at("el.addEventListener('x', 1)", () => document.body.addEventListener('x', 1));

    // --- a setter, for comparison with the constructor lead-in -----------
    at("url.href = 'nope'", () => { new URL('http://x.test/').href = 'nope'; });
    at("el.innerHTML = trusted-types?", () => { document.body.innerHTML = '<b>x</b>'; });

    return out;
})()
