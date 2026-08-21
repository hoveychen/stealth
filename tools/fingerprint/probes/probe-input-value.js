// Does `input.value = x` reach the `value` content attribute? Per spec that is
// not one answer but four: the value IDL attribute has a *mode* that depends on
// the input's type -- "value" (text, password, …) keeps the attribute out of it,
// while "default" (hidden, submit, reset, button, image) and "default/on"
// (checkbox, radio) reflect straight into it. "filename" (file) is read-only.
//
// This matters beyond serialization: Turnstile's hidden response input is where
// a challenge token lands, and the difference showed up as a 30-character gap
// in the widget container's innerHTML (results/turnstile-widget.md).
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${String(e.message).slice(0, 100)}`;
    }
  }

  const TYPES = [
    'hidden', 'text', 'search', 'tel', 'url', 'email', 'password', 'number',
    'submit', 'reset', 'button', 'image', 'checkbox', 'radio', 'file',
    'date', 'time', 'color', 'range', 'month', 'week', 'datetime-local',
  ];
  const mk = (type) => {
    const i = document.createElement('input');
    i.setAttribute('type', type);
    return i;
  };
  const A = (i) => JSON.stringify(i.getAttribute('value'));

  // ---- direction 1: property -> attribute -------------------------------
  // The reflecting types are the whole point; the non-reflecting ones are the
  // control that says we are not just writing the attribute everywhere.
  for (const type of TYPES) {
    T(`propToAttr_${type}`, () => {
      const i = mk(type);
      i.value = 'TOK';
      return `attr=${A(i)} prop=${JSON.stringify(i.value)}`;
    });
  }

  // ---- direction 2: attribute -> property -------------------------------
  for (const type of TYPES) {
    T(`attrToProp_${type}`, () => {
      const i = mk(type);
      i.setAttribute('value', 'FROM_ATTR');
      return `prop=${JSON.stringify(i.value)} default=${JSON.stringify(i.defaultValue)}`;
    });
  }

  // ---- serialization ----------------------------------------------------
  for (const type of ['hidden', 'text', 'submit', 'checkbox']) {
    T(`outerHTML_${type}`, () => {
      const i = mk(type);
      i.value = 'TOK';
      return i.outerHTML;
    });
  }

  // ---- defaultValue always reflects, whatever the mode ------------------
  for (const type of ['hidden', 'text', 'submit', 'checkbox']) {
    T(`defaultValue_${type}`, () => {
      const i = mk(type);
      i.defaultValue = 'DEF';
      return `attr=${A(i)} prop=${JSON.stringify(i.value)} default=${JSON.stringify(i.defaultValue)}`;
    });
  }

  // ---- the dirty value flag --------------------------------------------
  // In "value" mode, once the value has been set by script the attribute stops
  // driving the property. In "default" mode there is no such divergence.
  for (const type of ['hidden', 'text', 'submit', 'checkbox']) {
    T(`dirtyThenAttr_${type}`, () => {
      const i = mk(type);
      i.value = 'FIRST';
      i.setAttribute('value', 'SECOND');
      return `attr=${A(i)} prop=${JSON.stringify(i.value)}`;
    });
    T(`attrThenProp_${type}`, () => {
      const i = mk(type);
      i.setAttribute('value', 'FIRST');
      i.value = 'SECOND';
      return `attr=${A(i)} prop=${JSON.stringify(i.value)}`;
    });
    T(`removeAttrAfterProp_${type}`, () => {
      const i = mk(type);
      i.value = 'TOK';
      i.removeAttribute('value');
      return `attr=${A(i)} prop=${JSON.stringify(i.value)}`;
    });
  }

  // ---- switching type switches the mode ---------------------------------
  T('typeSwitch_textToHidden', () => {
    const i = mk('text');
    i.value = 'TOK';
    const before = A(i);
    i.setAttribute('type', 'hidden');
    return `beforeAttr=${before} afterAttr=${A(i)} prop=${JSON.stringify(i.value)}`;
  });
  T('typeSwitch_hiddenToText', () => {
    const i = mk('hidden');
    i.value = 'TOK';
    const before = A(i);
    i.setAttribute('type', 'text');
    return `beforeAttr=${before} afterAttr=${A(i)} prop=${JSON.stringify(i.value)}`;
  });
  T('noTypeAttribute', () => {
    const i = document.createElement('input');
    i.value = 'TOK';
    return `type=${i.type} attr=${A(i)} prop=${JSON.stringify(i.value)}`;
  });

  // ---- form reset ------------------------------------------------------
  T('formReset', () => {
    const f = document.createElement('form');
    const parts = [];
    for (const type of ['hidden', 'text', 'submit', 'checkbox']) {
      const i = mk(type);
      i.name = type;
      i.setAttribute('value', 'DEF');
      i.value = 'TOK';
      f.appendChild(i);
    }
    document.body.appendChild(f);
    f.reset();
    for (const i of Array.from(f.elements)) {
      parts.push(`${i.type}:attr=${i.getAttribute('value')},prop=${i.value}`);
    }
    f.remove();
    return parts.join(' | ');
  });

  // ---- what the widget actually does ------------------------------------
  T('turnstileShape', () => {
    const host = document.createElement('div');
    const i = document.createElement('input');
    i.type = 'hidden';
    i.name = 'cf-turnstile-response';
    i.id = 'cf-chl-widget-xxxxx_response';
    host.appendChild(i);
    const before = host.innerHTML.length;
    i.value = 'XXXX.DUMMY.TOKEN.XXXX';
    return `innerHTMLBefore=${before} innerHTMLAfter=${host.innerHTML.length} html=${host.innerHTML}`;
  });

  return { href: location.href, out };
})()
