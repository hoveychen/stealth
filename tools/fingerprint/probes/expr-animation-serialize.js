// How does Chrome write the `animation` shorthand back out? The Cloudflare
// @keyframes payload has seven rules that differ only here: the oracle says
// `animation: 0.3s cubic-bezier(0.55, 0.085, 0.68, 0.53) 0s 1 normal both
// running scale-up-center` where we say `animation: scale-up-center 0.3s
// cubic-bezier(...) both`. So Chrome writes every longhand, in a fixed order,
// with the name LAST -- pin that order, pin which longhands take part, and pin
// what happens when only some of them are set.
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
        // the exact oracle shapes
        probe('animation:scale-up-center 0.3s cubic-bezier(0.55,0.085,0.68,0.53) both'),
        probe('animation:stroke 0.4s cubic-bezier(0.65,0,0.45,1) 0.3s forwards'),
        probe('animation:fade-in-animation 0.1s 0.4s cubic-bezier(1,1,0,1) backwards'),
        probe('animation:unspin 0.7s cubic-bezier(0.65,0,0.45,1) forwards'),
        // minimal shorthands: how much does Chrome fill in?
        probe('animation:a'),
        probe('animation:1s a'),
        probe('animation:a 1s'),
        probe('animation:1s'),
        // every longhand written out, author order shuffled
        probe('animation:a 1s linear 2s 3 reverse both paused'),
        probe('animation:paused both reverse 3 2s linear 1s a'),
        // two durations = duration then delay
        probe('animation:a 1s 2s'),
        // iteration count spellings
        probe('animation:a 1s infinite'),
        probe('animation:a 1s 2.5'),
        // direction / fill-mode / play-state each alone
        probe('animation:a 1s alternate'),
        probe('animation:a 1s alternate-reverse'),
        probe('animation:a 1s forwards'),
        probe('animation:a 1s backwards'),
        probe('animation:a 1s running'),
        probe('animation:a 1s paused'),
        // timing function spellings
        probe('animation:a 1s ease'),
        probe('animation:a 1s ease-in-out'),
        probe('animation:a 1s steps(4, end)'),
        probe('animation:a 1s cubic-bezier(0.1,0.2,0.3,0.4)'),
        // case
        probe('animation:A 1s LINEAR BOTH'),
        // comma lists
        probe('animation:a 1s,b 2s'),
        probe('animation:a 1s linear both,b 2s ease forwards'),
        // does the shorthand absorb a longhand set after it?
        probe('animation:a 1s;animation-delay:2s'),
        probe('animation-delay:2s;animation:a 1s'),
        // longhands only, no shorthand: does cssText fold them back up?
        probe('animation-name:a;animation-duration:1s'),
        probe('animation-name:a;animation-duration:1s;animation-timing-function:linear;animation-delay:0s;animation-iteration-count:1;animation-direction:normal;animation-fill-mode:both;animation-play-state:running'),
        // a name that looks like a keyword
        probe('animation:none 1s'),
        probe('animation:1s none'),
        // is animation-timeline part of the shorthand?
        probe('animation:a 1s;animation-timeline:auto'),
        // the linear() easing, and the same easings inside `transition`, which
        // shares the timing-function slot's grammar
        probe('animation:a 1s linear(0,1)'),
        probe('transition:color 1s cubic-bezier(0.1,0.2,0.3,0.4)'),
        probe('transition:color 1s steps(4)'),
        probe('transition:color 1s linear(0,1)'),
        probe('transition:color 1s ease-in 2s'),
        // what do the individual longhands read back as?
        probe('animation-duration:0.3s'),
        probe('animation-iteration-count:1'),
        probe('animation-fill-mode:both'),
        probe('animation-play-state:running'),
    ], null, 0);
})()
