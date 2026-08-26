// The descriptor behind a name on a prototype: accessor or data, the
// function's own `length` and `name`, and whether it is enumerable and
// configurable. `getOwnPropertyNames` says a member exists; this says what
// shape to give it, which is what a binding needs before it can add one.
//
// The list is edited per batch -- it is a work sheet, not a fixed reading.
(() => {
    const wanted = {
        DOMException: ['toString'],
        DOMStringList: ['keys', 'values', 'entries'],
        Attr: ['prefix', 'specified'],
        StorageManager: ['persisted', 'persist'],
        SubtleCrypto: ['wrapKey', 'unwrapKey'],
        IDBFactory: ['databases'],
        IDBCursor: ['request'],
        Range: ['expand'],
        Blob: ['textStream'],
        Response: ['textStream'],
        File: ['lastModifiedDate', 'webkitRelativePath'],
        DOMMatrixReadOnly: ['toJSON', 'transformPoint'],
        AnimationEvent: ['animation'],
        TransitionEvent: ['animation'],
        HTMLDataListElement: ['options'],
        HTMLLabelElement: ['form'],
        HTMLLegendElement: ['form'],
        HTMLMapElement: ['areas'],
        HTMLTableCellElement: ['cellIndex'],
        HTMLTableRowElement: ['deleteCell'],
        HTMLTableSectionElement: ['deleteRow'],
        HTMLTitleElement: ['text'],
        HTMLEmbedElement: ['getSVGDocument'],
        InputEvent: ['getTargetRanges'],
        IntersectionObserverEntry: ['isVisible'],
        UIEvent: ['pseudoTarget'],
        EventTarget: ['when'],
        TransformStreamDefaultController: ['desiredSize'],
        SVGTransformList: ['createSVGTransformFromMatrix'],
        SpeechRecognition: ['unspokenPunctuation'],
        PerformanceEntry: ['navigationId'],
        DocumentType: ['after', 'before', 'replaceWith'],
        NamedNodeMap: ['getNamedItemNS', 'removeNamedItemNS', 'setNamedItemNS'],
        ScreenOrientation: ['onchange', 'lock', 'unlock'],
        VisualViewport: ['onresize', 'onscroll', 'onscrollend'],
        IDBDatabase: ['onabort', 'onclose', 'onversionchange'],
        HTMLMarqueeElement: ['loop', 'start', 'stop'],
        HTMLFormElement: ['rel', 'relList', 'reset'],
    };

    const out = {};
    for (const [iface, names] of Object.entries(wanted)) {
        const ctor = self[iface];
        if (typeof ctor !== 'function' || !ctor.prototype) { out[iface] = 'absent'; continue; }
        const rows = {};
        for (const name of names) {
            const d = Object.getOwnPropertyDescriptor(ctor.prototype, name);
            if (!d) { rows[name] = 'absent'; continue; }
            const fn = (f) => (typeof f === 'function' ? `len=${f.length} name=${JSON.stringify(f.name)}` : String(f));
            if ('value' in d) {
                rows[name] = `data ${fn(d.value)} w=${d.writable} e=${d.enumerable} c=${d.configurable}`;
            } else {
                rows[name] = `accessor get(${d.get ? fn(d.get) : 'none'}) set(${d.set ? fn(d.set) : 'none'}) e=${d.enumerable} c=${d.configurable}`;
            }
        }
        rows['@@symbols'] = Object.getOwnPropertySymbols(ctor.prototype).map(String).join(' ') || '(none)';
        rows['@@proto'] = (() => {
            const p = Object.getPrototypeOf(ctor.prototype);
            if (p === null) return 'null';
            const c = p.constructor;
            return (c && c.name) || '(anonymous)';
        })();
        out[iface] = rows;
    }
    return JSON.stringify(out);
})()
