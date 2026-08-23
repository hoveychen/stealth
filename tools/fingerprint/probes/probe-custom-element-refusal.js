// The other callers of the illegal-constructor refusal: a class that extends an
// element interface but was never registered, and a customized built-in reached
// through `new`. Naming the interface in the HTMLElement refusal must not put
// "Failed to construct 'HTMLElement'" on a message Chrome words differently.
(() => {
    const raised = (fn) => {
        try {
            const v = fn();
            return { throws: false, tag: v && v.tagName };
        } catch (e) {
            return { throws: true, name: e?.name ?? String(e), message: e?.message ?? '' };
        }
    };
    const out = {};

    class UnregisteredAutonomous extends HTMLElement {}
    out['new UnregisteredAutonomous()'] = raised(() => new UnregisteredAutonomous());

    class UnregisteredBuiltIn extends HTMLDivElement {}
    out['new UnregisteredBuiltIn()'] = raised(() => new UnregisteredBuiltIn());

    class Autonomous extends HTMLElement {}
    customElements.define('x-autonomous', Autonomous);
    out['new Autonomous() (registered)'] = raised(() => new Autonomous());

    class Fancy extends HTMLDivElement {}
    customElements.define('x-fancy', Fancy, { extends: 'div' });
    out['new Fancy() (registered built-in)'] = raised(() => new Fancy());

    // Registered autonomous whose superclass is the wrong interface for the tag.
    class Mismatch extends HTMLParagraphElement {}
    out['new Mismatch() (unregistered, p)'] = raised(() => new Mismatch());

    // super() twice in one constructor: the "already consumed" path.
    class DoubleSuper extends HTMLElement {
        constructor() {
            super();
            Reflect.construct(HTMLElement, [], DoubleSuper);
        }
    }
    customElements.define('x-double-super', DoubleSuper);
    out['new DoubleSuper()'] = raised(() => new DoubleSuper());

    // Reflect.construct with a new.target that is not a registered class.
    out['Reflect.construct(HTMLElement, [], Object)'] =
        raised(() => Reflect.construct(HTMLElement, [], Object));
    out['Reflect.construct(HTMLDivElement, [], Object)'] =
        raised(() => Reflect.construct(HTMLDivElement, [], Object));

    return JSON.stringify(out);
})()
