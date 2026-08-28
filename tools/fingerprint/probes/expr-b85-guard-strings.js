// The checks Kasada's own string heap names, read off ips.js rather than guessed.
//
// Every entry below quotes a literal recovered by kasada-decode-pool.mjs:
// `\[native code\]`, `^[a-z]+\s*\(\)\s*\{\s*[a-z]+\s*'?[a-zA-Z0-9]+'?;?\s*\}`,
// `class kekko extends Function.toString {}`, `Function.__proto__.toString.call()`,
// `Error.toString.call(1)`, `@@toPrimitive must return a primitive value.`,
// `Object.ErrorInInvocation`, `const me = window[bindingName]`, and the run of
// inch/point/centimetre constants. What the guard compares is the exact text,
// so the reading that matters is the exact text on both arms.
(() => {
    const out = {};
    const t = (f) => { try { return f(); } catch (e) { return 'THREW: ' + (e && e.message); } };

    // --- Function.prototype.toString on natives, by kind -------------------
    const natives = {
        'Function.prototype.toString': Function.prototype.toString,
        'JSON.stringify': JSON.stringify,
        'Array.prototype.push': Array.prototype.push,
        'Object.getOwnPropertyDescriptor': Object.getOwnPropertyDescriptor,
        'document.createElement': document.createElement,
        'window.setTimeout': window.setTimeout,
        'Element.prototype.getAttribute': Element.prototype.getAttribute,
        'CanvasRenderingContext2D.prototype.getImageData':
            window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype.getImageData,
        'Navigator.prototype.userAgent.get':
            (Object.getOwnPropertyDescriptor(Navigator.prototype, 'userAgent') || {}).get,
        'Navigator.prototype.languages.get':
            (Object.getOwnPropertyDescriptor(Navigator.prototype, 'languages') || {}).get,
        'Screen.prototype.width.get':
            (Object.getOwnPropertyDescriptor(Screen.prototype, 'width') || {}).get,
        'Permissions.prototype.query': window.Permissions && Permissions.prototype.query,
    };
    out.toString = {};
    for (const [k, fn] of Object.entries(natives)) {
        out.toString[k] = fn === undefined || fn === null
            ? '(absent)'
            : t(() => Function.prototype.toString.call(fn));
    }
    // The guard's own regexes, applied to the same strings it applies them to.
    const NATIVE_RE = /\[native code\]/;
    const PATCHED_RE = /^[a-z]+\s*\(\)\s*\{\s*[a-z]+\s*'?[a-zA-Z0-9]+'?;?\s*\}/;
    out.nativeCodeMisses = Object.entries(out.toString)
        .filter(([, v]) => v !== '(absent)' && !NATIVE_RE.test(v)).map(([k]) => k);
    out.looksPatched = Object.entries(out.toString)
        .filter(([, v]) => v !== '(absent)' && PATCHED_RE.test(v)).map(([k]) => k);
    out.fnNameShape = t(() => Function.prototype.toString.call(document.createElement).slice(0, 60));

    // --- error text the guard names verbatim -------------------------------
    out.err = {
        'class extends Function.toString': t(() => { class kekko extends Function.toString {} return String(kekko); }),
        'class extends JSON.stringify': t(() => { class kek extends JSON.stringify {} return String(kek); }),
        'class extends navigator.plugins': t(() => { class lel extends navigator.plugins {} return String(lel); }),
        'Function.__proto__.toString.call()': t(() => Function.__proto__.toString.call()),
        'Error.toString.call(1)': t(() => Error.prototype.toString.call(1)),
        'toPrimitive': t(() => { const o = {}; o[Symbol.toPrimitive] = () => ({}); return `${o}`; }),
        'Object.ErrorInInvocation': t(() => Object.ErrorInInvocation === undefined ? '(absent)' : 'PRESENT'),
        'Object.getDetails': t(() => Object.getDetails === undefined ? '(absent)' : 'PRESENT'),
        'permissions.stack': null, // filled below; async
        'proxy newHandler': t(() => { new Proxy({}, 1); return 'no error thrown'; }),
        'Reflect.get arity': t(() => Reflect.get()),
        'null property': t(() => { const n = null; return n.x; }),
        'not a function': t(() => { const o = {}; o.nope(); }),
        'undefined var': t(() => { /* eslint-disable-next-line no-undef */ return __b85_nope__.x; }),
    };

    // --- the inch/point/centimetre constants -------------------------------
    // `1.0521in`, `74.16pt`, `2.6162cm`, `0.9948in`, `1.0050in` ... are what a
    // computed-style read gives back after a unit round-trip.
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;width:0;height:0;visibility:hidden';
    document.documentElement.appendChild(d);
    out.units = {};
    for (const [name, css] of [['in', '1in'], ['pt', '1pt'], ['cm', '1cm'], ['mm', '1mm'],
        ['pc', '1pc'], ['q', '1Q'], ['ex', '1ex'], ['ch', '1ch']]) {
        d.style.width = css;
        out.units[name] = t(() => getComputedStyle(d).width);
    }
    // The literal `45px Arial` and `font: ` say the guard sets a shorthand and
    // reads the pieces back.
    d.style.cssText = 'font: 45px Arial';
    out.fontShorthand = t(() => {
        const cs = getComputedStyle(d);
        return [cs.font, cs.fontSize, cs.fontFamily, cs.lineHeight].join(' | ');
    });
    d.remove();

    // --- named tells that are plain reads ----------------------------------
    out.tells = {
        webdriver: t(() => String(navigator.webdriver)),
        allTag: t(() => Object.prototype.toString.call(document.all)),
        pluginsTag: t(() => Object.prototype.toString.call(navigator.plugins)),
        isSecureContext: t(() => String(window.isSecureContext)),
        vendor: t(() => navigator.vendor),
        platform: t(() => navigator.platform),
        languages: t(() => JSON.stringify(navigator.languages)),
        chromeObj: t(() => typeof window.chrome),
        mimeTypesLen: t(() => String(navigator.mimeTypes.length)),
        pluginsLen: t(() => String(navigator.plugins.length)),
    };
    // Property names the guard tests for existence and must not find.
    out.forbiddenGlobals = ['__playwright', '__pw_recorderRecordAction', '_phantom',
        'callPhantom', '__nightmare', 'domAutomation', 'domAutomationController',
        '__puppeteer_evaluation_script__', 'Object.getDetails']
        .filter((n) => n in window || n in document);

    return JSON.stringify(out, null, 1);
})()
