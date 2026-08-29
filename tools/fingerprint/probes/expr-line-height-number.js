// A unitless `line-height` inherits as the number, not as the px it resolved to
// on the parent.
//
// B59 read `line-height: 1.5` on a parent and `font-size: 72px` on the child:
// Chrome computed 108px on the child, this engine 24px -- it had folded 1.5
// against the parent's 16px and inherited that. This asks both arms the three
// forms (number, length, percentage) so the fix cannot quietly change the two
// that already agree.
(() => {
    const out = {};
    const host = document.createElement('div');
    document.body.appendChild(host);

    for (const parent of ['1.5', '30px', '150%', 'normal']) {
        host.style.cssText = 'font-size: 16px; line-height: ' + parent;
        const child = document.createElement('div');
        child.style.fontSize = '72px';
        host.appendChild(child);
        const grand = document.createElement('div');
        grand.style.fontSize = '10px';
        child.appendChild(grand);

        out[parent] = {
            parent: getComputedStyle(host).lineHeight,
            child: getComputedStyle(child).lineHeight,
            grandchild: getComputedStyle(grand).lineHeight,
        };
        host.textContent = '';
    }

    // ...and one where the child sets the number itself rather than inheriting.
    host.style.cssText = 'font-size: 16px';
    const own = document.createElement('div');
    own.style.cssText = 'font-size: 72px; line-height: 1.5';
    host.appendChild(own);
    out['own 1.5'] = getComputedStyle(own).lineHeight;

    host.remove();
    return out;
})()
