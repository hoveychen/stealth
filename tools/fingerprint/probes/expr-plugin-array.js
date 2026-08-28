// navigator.plugins is the second knob ever found to cost Chrome its ticket on
// cf-scrapingcourse -- 0 of 3 against a baseline of 3 of 3, with the same
// signature as webdriver-true. The lengths of the two arms' plugin dumps agree,
// which is not the same as the arms agreeing: this walks the whole surface --
// the array object, its indexed and named access, item/namedItem/refresh, the
// per-plugin mime types, and the prototypes behind all of it.
(() => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'ERR:' + e.name + ':' + e.message; } };
    const own = (o) => Object.getOwnPropertyNames(o);

    const P = navigator.plugins;
    const M = navigator.mimeTypes;

    t('plugins.length', () => P.length);
    t('plugins ctor', () => P.constructor && P.constructor.name);
    t('plugins own props', () => own(P));
    t('plugins proto own props', () => own(Object.getPrototypeOf(P)));
    t('plugins for-in', () => { const a = []; for (const k in P) a.push(k); return a; });
    t('plugins spread', () => { try { return [...P].length; } catch (e) { return 'ERR:' + e.name; } });
    t('plugins[0] name', () => P[0] && P[0].name);
    t('plugins named access', () => P['PDF Viewer'] && P['PDF Viewer'].name);
    t('plugins.item(0)', () => P.item(0) && P.item(0).name);
    t('plugins.namedItem', () => P.namedItem('PDF Viewer') && P.namedItem('PDF Viewer').name);
    t('plugins.refresh', () => { P.refresh(); return 'ok'; });
    t('plugins.length after refresh', () => P.length);
    t('plugins bare proto length', () => Object.create(Object.getPrototypeOf(P)).length);

    t('plugin list', () => Array.from(P).map((p) => ({
        name: p.name, filename: p.filename, description: p.description, length: p.length,
        ctor: p.constructor && p.constructor.name,
        own: own(p),
        mimes: Array.from(p).map((m) => ({ type: m.type, suffixes: m.suffixes, description: m.description,
            plugin: m.enabledPlugin && m.enabledPlugin.name })),
        item0: p.item(0) && p.item(0).type,
        named: p.namedItem('application/pdf') && p.namedItem('application/pdf').type,
    })));

    t('mimeTypes.length', () => M.length);
    t('mimeTypes ctor', () => M.constructor && M.constructor.name);
    t('mimeTypes proto own props', () => own(Object.getPrototypeOf(M)));
    t('mime list', () => Array.from(M).map((m) => ({ type: m.type, suffixes: m.suffixes,
        description: m.description, plugin: m.enabledPlugin && m.enabledPlugin.name, own: own(m) })));
    t('Plugin.prototype', () => own(Plugin.prototype));
    t('MimeType.prototype', () => own(MimeType.prototype));
    t('PluginArray.prototype', () => own(PluginArray.prototype));
    t('MimeTypeArray.prototype', () => own(MimeTypeArray.prototype));
    t('plugins===plugins', () => navigator.plugins === navigator.plugins);
    t('plugins[0]===plugins[0]', () => P[0] === P[0]);
    t('String(plugins)', () => String(P));
    t('String(plugins[0])', () => String(P[0]));
    return out;
})();
