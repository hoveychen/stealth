// Which element types land in `form.elements` and in `fieldset.elements`, and
// whether a nested fieldset's controls show up in both. The IDL calls both a
// "listed elements" collection but the two lists are not the same set, and
// `input type=image` is excluded from one of them.
(() => {
  const html = `
    <input name=i1>
    <input type=image name=i2>
    <input type=hidden name=i3>
    <button name=b1></button>
    <select name=s1></select>
    <textarea name=t1></textarea>
    <output name=o1></output>
    <object name=ob1></object>
    <fieldset name=f1><input name=i4></fieldset>
    <img name=im1>
    <a name=a1></a>
    <label name=l1></label>
    <progress name=p1></progress>
    <meter name=m1></meter>
    <keygen name=k1>
  `;
  const list = (c) => Array.from(c, (e) => e.tagName.toLowerCase() + (e.type ? '[' + e.type + ']' : '') + ':' + e.name).join(' ');

  const form = document.createElement('form');
  form.innerHTML = html;
  document.body.appendChild(form);

  const fs = document.createElement('fieldset');
  fs.innerHTML = html;
  document.body.appendChild(fs);

  const nested = document.createElement('form');
  nested.innerHTML = '<fieldset name=outer><input name=a><fieldset name=inner><input name=b></fieldset></fieldset>';
  document.body.appendChild(nested);

  return JSON.stringify({
    form_elements: { ctor: form.elements.constructor.name, length: form.elements.length, items: list(form.elements) },
    fieldset_elements: { ctor: fs.elements.constructor.name, length: fs.elements.length, items: list(fs.elements) },
    nested_form: list(nested.elements),
    nested_outer: list(nested.querySelector('fieldset[name=outer]').elements),
    nested_inner: list(nested.querySelector('fieldset[name=inner]').elements),
    // A fieldset's own elements collection: does it contain the fieldset itself
    // when the fieldset is nested inside another one?
    fieldset_named: (() => {
      try { return String(fs.elements.namedItem ? fs.elements.namedItem('i1') : 'no-namedItem'); } catch (e) { return 'threw: ' + e.message; }
    })(),
    fieldset_has_named_getter: 'namedItem' in fs.elements,
  });
})()
