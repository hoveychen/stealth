// A <style> inside a shadow root belongs to that root, not to the document.
//
// B59 built the Cloudflare widget's own shape -- attachShadow({mode:'closed'})
// with a <style> in it -- and read `document.styleSheets`: Chrome's count did
// not move and the rules were not reachable from the document, ours grew by one
// and the rules were readable. That is why our CSS-rule-text span in the widget
// payload came out exactly twice as long. This asks both arms about both modes,
// and about `document.adoptedStyleSheets` alongside, so the fix cannot silently
// take the sheet away from the shadow root too.
(() => {
    const out = {};
    const count = () => document.styleSheets.length;
    const ruleTexts = () => {
        const seen = [];
        for (const sheet of document.styleSheets) {
            let rules;
            try {
                rules = sheet.cssRules;
            } catch (e) {
                seen.push('(' + e.name + ')');
                continue;
            }
            for (const rule of rules) seen.push(rule.cssText);
        }
        return seen;
    };

    out.before = count();
    for (const mode of ['open', 'closed']) {
        const host = document.createElement('div');
        document.body.appendChild(host);
        const root = host.attachShadow({ mode });
        const style = document.createElement('style');
        style.textContent = '.' + mode + '-marker { color: rgb(1, 2, 3) }';
        root.appendChild(style);

        out[mode] = {
            documentCount: count(),
            documentSeesMarker: ruleTexts().some((t) => t.indexOf(mode + '-marker') !== -1),
            shadowCount: root.styleSheets.length,
            shadowSeesMarker: root.styleSheets.length > 0 &&
                root.styleSheets[0].cssRules[0].cssText.indexOf(mode + '-marker') !== -1,
            sheetOwnerNode: style.sheet ? style.sheet.ownerNode === style : null,
        };
        host.remove();
        out[mode].afterRemove = count();
    }
    out.after = count();
    return out;
})()
