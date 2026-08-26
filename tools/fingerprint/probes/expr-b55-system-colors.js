// What does a computed `color` answer for a system colour keyword, and for a
// name that is not a colour at all?
//
// Kasada asks this at x-hyatt: the live capture (inject-b55-answers.js,
// results/b55-answers-{lp,chrome}.json) has it setting `color` to each of about
// ninety keywords and reading the computed value back with
// `getPropertyValue('color')`. Chrome answers with twelve distinct `rgb(...)`
// strings; this engine answers with the keyword it was handed -- including the
// forty-four `-moz-` names that only Firefox has ever supported, and including
// `FakeColor`, which Kasada plants as its control precisely because no browser
// resolves it.
//
// Two things are being checked, and they are separate bugs:
//   * a recognised system colour must compute to the `rgb(...)` it names,
//   * an unrecognised identifier must not be accepted at all, so `color` keeps
//     the value it had.
const KEYWORDS = [
    // CSS Color 4 system colours, which Chrome does support.
    'accentcolor', 'accentcolortext', 'canvas', 'canvastext', 'field', 'fieldtext',
    'buttonborder', 'buttonface', 'buttontext', 'selecteditem', 'selecteditemtext',
    'mark', 'marktext', 'linktext', 'visitedtext', 'activetext', 'graytext',
    'highlight', 'highlighttext',
    // Deprecated CSS2 system colours, which Chrome still resolves.
    'activeborder', 'activecaption', 'appworkspace', 'background', 'buttonhighlight',
    'buttonshadow', 'captiontext', 'inactiveborder', 'inactivecaption',
    'inactivecaptiontext', 'infobackground', 'infotext', 'menu', 'menutext',
    'scrollbar', 'threeddarkshadow', 'threedface', 'threedhighlight',
    'threedlightshadow', 'threedshadow', 'window', 'windowframe', 'windowtext',
    // Firefox-only names, which Chrome does not support.
    '-moz-ButtonDefault', '-moz-CellHighlight', '-moz-Dialog', '-moz-DialogText',
    '-moz-Field', '-moz-FieldText', '-moz-mac-accentface', '-moz-mac-focusring',
    '-moz-hyperlinktext', '-moz-default-color',
    // Kasada's own control: not a colour under any engine.
    'FakeColor',
];
(() => {
    const out = {};
    const d = document.createElement('div');
    d.style.color = 'rgb(1, 2, 3)';
    document.body.appendChild(d);
    for (const k of KEYWORDS) {
        d.style.color = 'rgb(1, 2, 3)';
        try { d.style.color = k; } catch (e) { /* setter never throws, but be safe */ }
        out[k] = getComputedStyle(d).getPropertyValue('color');
    }
    d.remove();
    return out;
})();
