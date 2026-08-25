// `@view-transition` and the CSSViewTransitionRule it becomes: which
// descriptors survive, how the rule re-serialises, and what an invalid value
// does. The interface object is already on the window in both engines; the
// question is whether the at-rule parses into one at all.
(() => {
    const out = {};
    const look = (key, css) => {
        const style = document.createElement('style');
        style.textContent = css;
        document.head.appendChild(style);
        try {
            const rules = style.sheet.cssRules;
            if (rules.length === 0) {
                out[key] = 'no-rule';
                return;
            }
            const r = rules[0];
            const ctor = r.constructor.name;
            if (ctor !== 'CSSViewTransitionRule') {
                out[key] = 'ctor=' + ctor + ' type=' + r.type + ' cssText=' + r.cssText;
                return;
            }
            out[key] = [
                'type=' + r.type,
                'navigation=' + r.navigation,
                'types=[' + Array.from(r.types).join(',') + ']',
                'frozen=' + Object.isFrozen(r.types),
                'fresh=' + (r.types !== r.types),
                'cssText=' + r.cssText,
            ].join(' | ');
        } catch (e) {
            out[key] = 'threw:' + (e && e.name) + ':' + (e && e.message);
        } finally {
            style.remove();
        }
    };

    look('auto + two types', '@view-transition { navigation: auto; types: a b; }');
    look('empty block', '@view-transition {}');
    look('navigation none', '@view-transition { navigation: none; }');
    look('navigation bogus', '@view-transition { navigation: sideways; }');
    look('navigation missing, types only', '@view-transition { types: only-this; }');
    look('types none', '@view-transition { navigation: auto; types: none; }');
    look('types with a bogus token', '@view-transition { navigation: auto; types: ok 4px; }');
    look('types repeated descriptor', '@view-transition { types: a; types: b; }');
    look('uppercase keyword', '@VIEW-TRANSITION { navigation: AUTO; types: A; }');
    look('no block', '@view-transition;');
    look('unknown descriptor', '@view-transition { navigation: auto; wat: 1; }');
    look('inside media', '@media all { @view-transition { navigation: auto; } }');
    look('types comma separated', '@view-transition { types: a, b; }');
    look('types none plus ident', '@view-transition { types: none a; }');
    look('types empty value', '@view-transition { types: ; }');
    look('navigation empty value', '@view-transition { navigation: ; }');
    look('types auto keyword', '@view-transition { types: auto; }');
    look('types initial keyword', '@view-transition { types: initial; }');
    look('types leading double dash', '@view-transition { types: --custom; }');
    look('prelude present', '@view-transition foo { navigation: auto; }');
    look('navigation twice, second bogus', '@view-transition { navigation: auto; navigation: nope; }');
    look('types before navigation', '@view-transition { types: a; navigation: auto; }');
    look('types inherit', '@view-transition { types: inherit; }');
    look('types unset', '@view-transition { types: unset; }');
    look('types revert', '@view-transition { types: revert; }');
    look('types none twice in list', '@view-transition { types: none none; }');
    look('types extra whitespace', '@view-transition { types:   a\n b  ; }');
    look('types quoted string', '@view-transition { types: "a"; }');
    look('navigation with !important', '@view-transition { navigation: auto !important; }');

    // The interface object itself, for the record.
    out['typeof CSSViewTransitionRule'] = typeof CSSViewTransitionRule;
    out['CSSViewTransitionRule.prototype keys'] =
        Object.getOwnPropertyNames(CSSViewTransitionRule.prototype).join(' ');
    return out;
})()
