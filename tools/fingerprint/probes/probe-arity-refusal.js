// What each engine does when an operation is called with fewer arguments than
// its WebIDL `length`, for the members where the two engines disagree about
// what that length is.
//
// probe-operation-arity.js measures the lengths; this measures the behaviour
// they imply. Both halves are needed before a required-argument check can be
// turned on: `Caller.getArgs` already refuses a missing non-optional parameter
// (with the generic "invalid argument"), but it refuses it *after* converting
// the earlier arguments, and the count it refuses against is derived from the
// Zig signature rather than from WebIDL. Where that derived count is too high,
// moving the check to the front of the call would newly throw on a call Chrome
// accepts -- so every such member is called here with too few arguments to see
// which engine speaks.
//
// Three groups:
//   * over-throw candidates -- our length exceeds Chrome's (variadics, and
//     optional parameters we made required)
//   * the arity sentence -- members where both engines refuse, to pin Blink's
//     wording
//   * under-report samples -- our length is below Chrome's, so Chrome refuses
//     and we silently accept
//
// Run against a real http page (needs a document and a storage area):
//
//   PROBE_PORT=<p> node tools/fingerprint/run-probe.mjs <engine> \
//       tools/fingerprint/probes/probe-arity-refusal.js http://127.0.0.1:<q>/
(() => {
    const raised = (fn) => {
        try {
            fn();
            return { throws: false };
        } catch (e) {
            return { throws: true, name: e?.name ?? String(e), message: e?.message ?? '' };
        }
    };
    const out = {};
    const at = (label, fn) => { out[label] = raised(fn); };

    const div = document.createElement('div');
    const text = document.createTextNode('x');
    const frag = document.createDocumentFragment();
    // A detached document, so write()/writeln() cannot disturb the page we are
    // measuring on.
    const doc = document.implementation.createHTMLDocument('probe');

    // --- over-throw candidates: variadic operations -----------------------
    at("el.append()", () => div.append());
    at("el.prepend()", () => div.prepend());
    at("el.replaceChildren()", () => div.replaceChildren());
    at("el.after()", () => div.after());
    at("el.before()", () => div.before());
    at("el.replaceWith()", () => div.replaceWith());
    at("text.after()", () => text.after());
    at("text.before()", () => text.before());
    at("text.replaceWith()", () => text.replaceWith());
    at("frag.append()", () => frag.append());
    at("frag.prepend()", () => frag.prepend());
    at("frag.replaceChildren()", () => frag.replaceChildren());
    at("doc.append()", () => doc.append());
    at("doc.prepend()", () => doc.prepend());
    at("doc.replaceChildren()", () => doc.replaceChildren());
    at("doc.write()", () => doc.write());
    at("doc.writeln()", () => doc.writeln());
    at("el.classList.add()", () => div.classList.add());
    at("el.classList.remove()", () => div.classList.remove());
    at("document.all.item()", () => document.all.item());

    // --- over-throw candidates: optional parameters we made required ------
    at("clearTimeout()", () => clearTimeout());
    at("clearInterval()", () => clearInterval());
    at("window.scroll()", () => window.scroll());
    at("window.scrollTo()", () => window.scrollTo());
    at("window.scrollBy()", () => window.scrollBy());
    at("selection.containsNode(node)", () => getSelection().containsNode(div));
    at("selection.modify()", () => getSelection().modify());
    at("writer.write()", () => new WritableStream().getWriter().write());
    at("transformController.enqueue()", () => {
        let controller;
        new TransformStream({ start(c) { controller = c; } });
        controller.enqueue();
    });

    // --- the arity sentence: both engines refuse ---------------------------
    at("document.createElement()", () => document.createElement());
    at("el.setAttribute('x')", () => div.setAttribute('x'));
    at("el.matches()", () => div.matches());
    at("el.closest()", () => div.closest());
    at("document.querySelector()", () => document.querySelector());
    at("history.pushState()", () => history.pushState());
    at("localStorage.setItem('k')", () => localStorage.setItem('k'));
    at("el.getAttribute()", () => div.getAttribute());
    at("el.removeAttribute()", () => div.removeAttribute());
    at("document.createTextNode()", () => document.createTextNode());
    at("el.querySelectorAll()", () => div.querySelectorAll());
    at("document.getElementsByClassName()", () => document.getElementsByClassName());
    at("new URL()", () => new URL());

    // --- under-report samples: Chrome refuses, we accept -------------------
    at("node.contains()", () => div.contains());
    at("document.getElementById()", () => document.getElementById());
    at("node.isSameNode()", () => div.isSameNode());
    at("el.hasAttributeNS()", () => div.hasAttributeNS());
    at("document.createElementNS()", () => document.createElementNS());
    at("history.pushState(1)", () => history.pushState(1));

    return out;
})()
