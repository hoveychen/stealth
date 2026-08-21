// What Chrome does with a two-value property written as a pair.
//
// The engine keeps a list (`isTwoValueShorthand`) of properties whose value it
// folds from `X X` to `X`, and folding is only one of the three rules Chrome
// actually applies:
//
//   * fold the pair when both halves are equal (`gap: 10px 10px` -> `10px`);
//   * drop a trailing `auto` (`background-size: 10px auto` -> `10px`) while
//     keeping an equal pair (`10px 10px` stays);
//   * rewrite the pair as a keyword of its own (`background-repeat:
//     repeat no-repeat` -> `repeat-x`).
//
// This reads every member of that list, both directions of every asymmetric
// pair, and the symmetric twins the list is missing, so the rule per property
// is measured rather than assumed. What it said:
//
//   * fold-on-equal is right for all 22 non-size, non-repeat members, and
//     `-webkit-mask-box-image-repeat` wants it too;
//   * `background-size` / `mask-size` / `-webkit-mask-size` do not fold --
//     `10px 10px` stays a pair, `10px auto` and `auto auto` lose the trailing
//     `auto`, `auto 10px` keeps both;
//   * `background-repeat` / `mask-repeat` / `-webkit-mask-repeat` fold on
//     equal *and* answer `repeat no-repeat` with `repeat-x`, `no-repeat repeat`
//     with `repeat-y`; every other mixed pair stays a pair, and `repeat-x`
//     itself is a single value that no pair may contain;
//   * both rules run per comma-separated layer -- `background-repeat: repeat,
//     repeat no-repeat` answers `repeat, repeat-x`.
//
// The four-value box family (`margin`, `padding`, `inset`, `border-width`,
// ...) elides the same way and already agrees, because those go out through
// the shorthand table rather than through this fold. `border-radius`, the
// shadow lists and `text-emphasis`'s reorder do not agree, and are not this
// probe's business.
(() => {
    // Per property: the pairs worth asking about. A pair is listed in both
    // orders wherever the order could matter, because a rule that rewrites
    // `a b` and one that folds it read the same on `a a`.
    const cases = {
        'place-content': [
            'center center', 'start start', 'center start', 'start center',
            'space-between space-between', 'baseline baseline', 'normal normal',
            'end end', 'stretch stretch', 'center normal', 'normal center',
        ],
        'place-items': [
            'center center', 'start start', 'center start', 'baseline baseline',
            'normal normal', 'stretch stretch', 'center normal', 'normal center',
            'end end',
        ],
        'place-self': [
            'center center', 'start start', 'center start', 'auto auto',
            'auto center', 'center auto', 'stretch stretch', 'end end',
        ],
        'margin-block': [
            '10px 10px', '10px 20px', 'auto auto', '10px auto', 'auto 10px',
            '0 0', '0px 0px',
        ],
        'margin-inline': ['10px 10px', '10px 20px', 'auto auto', '10px auto', 'auto 10px'],
        'padding-block': ['10px 10px', '10px 20px', '0 0'],
        'padding-inline': ['10px 10px', '10px 20px'],
        'inset-block': ['10px 10px', '10px 20px', 'auto auto', '10px auto', 'auto 10px'],
        'inset-inline': ['10px 10px', '10px 20px', 'auto auto', '10px auto', 'auto 10px'],
        'border-block-style': ['solid solid', 'solid dashed', 'none none', 'none solid', 'solid none'],
        'border-inline-style': ['solid solid', 'solid dashed', 'none none'],
        'border-block-width': ['1px 1px', '1px 2px', 'thin thin', 'thin medium', 'medium medium'],
        'border-inline-width': ['1px 1px', '1px 2px', 'thin thin', 'medium medium'],
        'border-block-color': ['red red', 'red blue', 'currentColor currentColor', 'red currentColor'],
        'border-inline-color': ['red red', 'red blue', 'currentColor currentColor'],
        'overflow': [
            'hidden hidden', 'hidden auto', 'auto hidden', 'visible visible',
            'auto auto', 'visible auto', 'auto visible', 'clip clip', 'scroll scroll',
        ],
        'overscroll-behavior': [
            'contain contain', 'none none', 'auto auto', 'contain none', 'none contain',
            'auto contain', 'contain auto',
        ],
        'gap': ['10px 10px', '10px 20px', 'normal normal', 'normal 10px', '10px normal', '0 0'],
        'grid-gap': ['10px 10px', '10px 20px', 'normal normal', '10px normal'],
        'scroll-padding-block': ['10px 10px', '10px 20px', 'auto auto', '10px auto', 'auto 10px'],
        'scroll-padding-inline': ['10px 10px', '10px 20px', 'auto auto', '10px auto'],
        'scroll-snap-align': ['start start', 'none none', 'start end', 'end start', 'center center', 'none start', 'start none'],
        'background-size': [
            '10px', 'auto', 'cover', 'contain', 'auto auto', '10px auto',
            'auto 10px', '10px 10px', '10px 20px', '50% auto', 'auto 50%', '0 0',
        ],
        'mask-size': [
            '10px', 'auto', 'cover', 'contain', 'auto auto', '10px auto',
            'auto 10px', '10px 10px', '10px 20px',
        ],
        '-webkit-mask-size': ['auto auto', '10px auto', 'auto 10px', '10px 10px', '10px 20px'],
        'background-repeat': [
            'repeat', 'no-repeat', 'repeat-x', 'repeat-y', 'space', 'round',
            'repeat repeat', 'no-repeat no-repeat', 'repeat no-repeat',
            'no-repeat repeat', 'space round', 'round space', 'space space',
            'round round', 'repeat space', 'space repeat', 'repeat round',
            'round repeat', 'no-repeat space', 'space no-repeat',
            'repeat-x repeat-x', 'repeat-x no-repeat',
        ],
        'mask-repeat': [
            'repeat repeat', 'no-repeat no-repeat', 'repeat no-repeat',
            'no-repeat repeat', 'space round', 'round space', 'space space',
            'repeat space', 'no-repeat space',
        ],
        '-webkit-mask-repeat': ['repeat repeat', 'repeat no-repeat', 'no-repeat repeat', 'space round'],
        'border-image-repeat': [
            'stretch stretch', 'repeat repeat', 'stretch repeat', 'repeat stretch',
            'round round', 'space space', 'round space', 'stretch round',
        ],
        '-webkit-mask-box-image-repeat': ['stretch stretch', 'stretch repeat', 'repeat repeat'],
        // Symmetric twins the list does not name -- measured so the omission is
        // a reading rather than an oversight.
        'scroll-margin-block': ['10px 10px', '10px 20px', '0 0'],
        'scroll-margin-inline': ['10px 10px', '10px 20px'],
        'border-spacing': ['1px 1px', '1px 2px', '0 0', '0px 0px'],
        'contain-intrinsic-size': ['10px 10px', '10px 20px', 'auto 10px 10px', 'none none'],
        'inset': ['10px 10px', '10px 20px', 'auto auto'],
        'perspective-origin': ['center center', 'left top', '10px 10px', '50% 50%'],
        'transform-origin': ['center center', 'left top', '10px 10px', '50% 50%'],
        'background-position': ['center center', '10px 10px', 'left top', '50% 50%'],
        'mask-position': ['center center', '10px 10px', 'left top'],
        'border-block': ['1px 1px', 'solid solid'],
        'text-emphasis': ['filled circle', 'circle filled'],
        'grid-row': ['1 / 1', 'auto / auto', '1 / 2'],
        'grid-column': ['1 / 1', 'auto / auto'],
        'cue': ['10px', '10px 10px'],
    };

    const out = {};
    for (const [property, values] of Object.entries(cases)) {
        for (const value of values) {
            const el = document.createElement('div');
            el.style.setProperty(property, value);
            const names = [];
            for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
            out[`${property}: ${value}`] = {
                items: names,
                values: names.map((n) => el.style.getPropertyValue(n)),
                read: el.style.getPropertyValue(property),
                cssText: el.style.cssText,
            };
        }
    }
    return out;
})()
