// How does Chrome write the `border-image` longhands back out? Rule 116 of the
// Cloudflare @keyframes payload is the one place this engine writes MORE than
// Chrome: we spell all five `border-image-*` longhands where the oracle says
// `border-image: none`. Feed Chrome the exact text we recorded and see what it
// folds it back into.
(() => {
    const sheet = new CSSStyleSheet();
    const probe = (decl) => {
        let text = null;
        let err = null;
        try {
            sheet.replaceSync('x{' + decl + '}');
            text = sheet.cssRules[0].style.cssText;
        } catch (e) {
            err = String((e && e.name) || e);
        }
        return { in: decl, cssText: text, err };
    };
    return JSON.stringify([
        // the exact declaration block we recorded for rule 116
        probe('top: 0px; left: 5px; border-width: 0px 4px 4px 0px; border-style: solid; border-color: rgb(196, 77, 14); border-top-width: 0px; border-image-source: none; border-image-slice: 100%; border-image-width: 1; border-image-outset: 0; border-image-repeat: stretch; border-radius: 0px; width: 6px; height: 12px;'),
        // the five longhands at their initial values, alone
        probe('border-image-source:none;border-image-slice:100%;border-image-width:1;border-image-outset:0;border-image-repeat:stretch'),
        // the shorthand itself, in each shape
        probe('border-image:none'),
        probe('border-image:url(a) 30'),
        probe('border-image:url(a) 30 / 19px / 2px round'),
        probe('border-image:linear-gradient(red,blue) 27 fill / 35px / 10px space'),
        // when does the shorthand collapse to just its source?
        probe('border-image:url(a)'),
        probe('border-image:url(a) stretch'),
        probe('border-image:url(a) 100%'),
        probe('border-image:url(a) 1 / 1 / 0 stretch'),
        probe('border-image:none 30'),
        probe('border-image:none 1 / 1 / 0 round'),
        // all five longhands set individually to a non-initial mix
        probe('border-image-source:url(a);border-image-slice:30;border-image-width:1;border-image-outset:0;border-image-repeat:stretch'),
        probe('border-image-source:none;border-image-slice:100%;border-image-width:2px;border-image-outset:0;border-image-repeat:stretch'),
        // partial sets: does one non-initial longhand bring the shorthand back?
        probe('border-image-source:url(a)'),
        probe('border-image-source:none'),
        probe('border-image-slice:100%'),
        probe('border-image-width:1'),
        probe('border-image-repeat:stretch'),
        probe('border-image-source:none;border-image-slice:50%'),
        // what the author most likely wrote, and what Chrome makes of it
        probe('border:solid rgb(196, 77, 14);border-width:0 4px 4px 0'),
        probe('border:0 solid rgb(196, 77, 14);border-width:0 4px 4px 0'),
        // border on its own, all four sides equal
        probe('border:2px solid red'),
    ], null, 0);
})()
