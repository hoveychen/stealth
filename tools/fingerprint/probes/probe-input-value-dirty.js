// The dirty value flag, which is what decides whether the `value` content
// attribute still reaches the `value` property. `probe-input-sanitize.js`
// measured *what* each type does to a value; this measures *when* the attribute
// gets to seed one at all -- the type switches, the attribute removals, the
// clone, and the two validity bits that are supposed to be dirty-gated.
//
// Every cell is a small scripted sequence -> what .value / .defaultValue / the
// attribute read back, so the output is a table to implement against.
(() => {
  const out = {};
  const show = (s) => JSON.stringify(s);
  const mk = (type) => {
    const i = document.createElement('input');
    i.setAttribute('type', type);
    return i;
  };
  const rd = (i) => `prop=${show(i.value)} default=${show(i.defaultValue)} attr=${show(i.getAttribute('value'))}`;

  // A dirty value outranks a later attribute write -- including a dirty value
  // the sanitizer rejected, which reads "" and stays dirty.
  { const i = mk('number'); i.value = '12'; i.setAttribute('value', 'TOK'); out.dirty_then_attr = rd(i); }
  { const i = mk('number'); i.value = 'TOK'; i.setAttribute('value', '12'); out.dirtyRejected_then_attr = rd(i); }
  { const i = mk('number'); i.setAttribute('value', 'TOK'); i.setAttribute('value', '12'); out.attr_then_attr = rd(i); }

  // Removing the attribute drops a seeded value but not a dirty one.
  { const i = mk('number'); i.setAttribute('value', '12'); i.removeAttribute('value'); out.attr_then_remove = rd(i); }
  { const i = mk('number'); i.setAttribute('value', '12'); i.value = '7'; i.removeAttribute('value'); out.attr_dirty_then_remove = rd(i); }

  // defaultValue writes the attribute, so it seeds through the sanitizer and
  // reads back unsanitized itself.
  { const i = mk('number'); i.defaultValue = 'TOK'; out.defaultValue_setter = rd(i); }

  // Type switches. The sanitizer runs over the value the element currently
  // *has*, so relaxing number -> text does not recover the attribute's "TOK";
  // only arriving from a non-value mode re-reads the attribute.
  { const i = mk('text'); i.setAttribute('value', 'TOK'); i.setAttribute('type', 'number'); out.attr_then_typeSwitch = rd(i); }
  { const i = mk('hidden'); i.setAttribute('value', 'TOK'); i.setAttribute('type', 'number'); out.hiddenAttr_then_typeSwitch = rd(i); }
  { const i = mk('number'); i.setAttribute('value', 'TOK'); i.removeAttribute('type'); out.number_removeType = rd(i); }
  { const i = mk('hidden'); i.setAttribute('value', 'TOK'); i.removeAttribute('type'); out.hidden_removeType = rd(i); }
  { const i = mk('number'); i.value = '12'; i.removeAttribute('type'); out.dirtyNumber_removeType = rd(i); }

  // Leaving value mode banks a dirty value into the attribute -- but a pristine
  // one must be left alone, or the raw attribute loses to its sanitized form.
  { const i = mk('number'); i.setAttribute('value', 'TOK'); i.setAttribute('type', 'hidden'); out.pristineNumber_to_hidden = rd(i); }
  { const i = mk('text'); i.value = 'TOK'; i.setAttribute('type', 'hidden'); i.setAttribute('type', 'number'); out.dirtyText_hidden_number = rd(i); }
  { const i = mk('text'); i.value = '12'; i.setAttribute('type', 'hidden'); i.setAttribute('type', 'number'); out.dirtyText12_hidden_number = rd(i); }

  // cloneNode carries the value and the flag across.
  { const i = mk('number'); i.value = '12'; i.setAttribute('value', 'TOK'); out.clone_dirty = rd(i.cloneNode(false)); }
  { const i = mk('number'); i.setAttribute('value', 'TOK'); out.clone_pristine = rd(i.cloneNode(false)); }

  // The parser is the other entry point into the same seeding.
  {
    const d = document.createElement('div');
    d.innerHTML = '<input type="number" value="TOK"><input type="date" value="2026-13-01">';
    out.parsed_number = rd(d.children[0]);
    out.parsed_date = rd(d.children[1]);
  }

  // Which validity bits are dirty-gated. tooLong/tooShort are, and Chrome goes
  // further than the dirty flag: it wants a *user* edit, so a scripted
  // assignment does not arm them either. typeMismatch/patternMismatch are not
  // gated at all and do read a seeded value.
  const validity = (type, attrs, assign) => {
    const i = mk(type);
    for (const [k, v] of Object.entries(attrs)) i.setAttribute(k, v);
    if (assign !== undefined) i.value = assign;
    const v = i.validity;
    return `tooShort=${v.tooShort} tooLong=${v.tooLong} typeMismatch=${v.typeMismatch} patternMismatch=${v.patternMismatch}`;
  };
  out.seeded_tooShort = validity('text', { minlength: '3', value: 'ab' });
  out.seeded_tooLong = validity('text', { maxlength: '2', value: 'abcdef' });
  out.scriptDirty_tooShort = validity('text', { minlength: '3' }, 'ab');
  out.scriptDirty_tooLong = validity('text', { maxlength: '2' }, 'abcdef');
  out.seeded_typeMismatch = validity('email', { value: 'bad' });
  out.seeded_patternMismatch = validity('text', { pattern: '\\d+', value: 'abc' });

  return { href: location.href, out };
})()
