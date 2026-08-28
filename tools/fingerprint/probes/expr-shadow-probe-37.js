// The widget's 85-byte span reads
//
//   [null,"closed","<body></body>","",4,4,N,"function attachShadow() { [native code] }"]
//
// with N=37 in Chrome and N=33 here -- the one stable numeric disagreement in a
// span whose other seven slots match. This enumerates the counts a shadow-root
// probe plausibly reports, so the diff names which reading N is.
(() => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'ERR:' + e.name; } };

    const host = document.createElement('div');
    document.body.appendChild(host);
    const sr = host.attachShadow({ mode: 'closed' });
    sr.innerHTML = '<body></body>';

    t('host.shadowRoot', () => host.shadowRoot);
    t('sr.mode', () => sr.mode);
    t('sr.innerHTML', () => sr.innerHTML);
    t('host.innerHTML', () => host.innerHTML);
    t('sr.childNodes.length', () => sr.childNodes.length);
    t('sr.children.length', () => sr.children.length);
    t('sr.nodeType', () => sr.nodeType);
    t('attachShadow.toString()', () => Element.prototype.attachShadow.toString());
    t('attachShadow.toString().length', () => Element.prototype.attachShadow.toString().length);

    t('gopn(ShadowRoot.prototype).length', () => Object.getOwnPropertyNames(ShadowRoot.prototype).length);
    t('gopn(ShadowRoot).length', () => Object.getOwnPropertyNames(ShadowRoot).length);
    t('gopn(sr).length', () => Object.getOwnPropertyNames(sr).length);
    t('gopn(DocumentFragment.prototype).length', () => Object.getOwnPropertyNames(DocumentFragment.prototype).length);
    t('gopn(DocumentOrShadowRoot).length', () => Object.getOwnPropertyNames(sr.constructor.prototype).length);
    t('for-in(sr) count', () => { let n = 0; for (const k in sr) n++; return n; });
    t('for-in(ShadowRoot.prototype) count', () => { let n = 0; for (const k in ShadowRoot.prototype) n++; return n; });

    t('gopn(Element.prototype).length', () => Object.getOwnPropertyNames(Element.prototype).length);
    t('gopn(HTMLElement.prototype).length', () => Object.getOwnPropertyNames(HTMLElement.prototype).length);
    t('gopn(Node.prototype).length', () => Object.getOwnPropertyNames(Node.prototype).length);
    t('gopn(Document.prototype).length', () => Object.getOwnPropertyNames(Document.prototype).length);
    t('gopn(HTMLBodyElement.prototype).length', () => Object.getOwnPropertyNames(HTMLBodyElement.prototype).length);

    t('sr.styleSheets.length', () => sr.styleSheets.length);
    t('sr.adoptedStyleSheets.length', () => sr.adoptedStyleSheets.length);
    t('document.styleSheets.length', () => document.styleSheets.length);
    t('sr.host.tagName.length', () => sr.host.tagName.length);
    t('String(sr).length', () => String(sr).length);
    t('sr.toString()', () => sr.toString());
    t('sr.textContent.length', () => sr.textContent.length);
    t('document.all.length', () => document.all.length);
    t('document.querySelectorAll("*").length', () => document.querySelectorAll('*').length);
    t('sr.querySelectorAll("*").length', () => sr.querySelectorAll('*').length);
    t('sr.activeElement', () => String(sr.activeElement));
    t('gopn(Object.getPrototypeOf(sr)).length', () => Object.getOwnPropertyNames(Object.getPrototypeOf(sr)).length);
    t('proto chain names', () => {
        const names = [];
        let p = sr;
        while ((p = Object.getPrototypeOf(p))) names.push(p.constructor && p.constructor.name);
        return names.join(',');
    });

    host.remove();
    return out;
})();
