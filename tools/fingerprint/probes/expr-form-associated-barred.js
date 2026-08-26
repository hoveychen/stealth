// What the constraint-validation members answer on the three elements that are
// *barred* from constraint validation -- fieldset, output and object -- plus
// output's value/defaultValue pair and object's document accessors. Every one
// of these is a value the IDL does not pin down, so they have to be read off a
// browser rather than derived.
(() => {
  const out = {};
  const validity = (v) => {
    const o = {};
    for (const k in v) o[k] = v[k];
    return o;
  };
  const form = document.createElement('form');
  document.body.appendChild(form);

  for (const tag of ['fieldset', 'output', 'object']) {
    const el = document.createElement(tag);
    form.appendChild(el);
    const rec = {
      type: String(el.type),
      form_is_form: el.form === form,
      willValidate: el.willValidate,
      validity_ctor: el.validity.constructor.name,
      validity: validity(el.validity),
      validationMessage: el.validationMessage,
      checkValidity: el.checkValidity(),
      reportValidity: el.reportValidity(),
    };
    let invalid_fired = false;
    el.addEventListener('invalid', () => { invalid_fired = true; });
    el.setCustomValidity('boom');
    rec.after_custom = {
      willValidate: el.willValidate,
      customError: el.validity.customError,
      valid: el.validity.valid,
      validationMessage: el.validationMessage,
      checkValidity: el.checkValidity(),
      invalid_fired,
    };
    rec.validity_same_object = el.validity === el.validity;
    out[tag] = rec;
  }

  // Detached from any form.
  for (const tag of ['fieldset', 'output', 'object']) {
    const el = document.createElement(tag);
    out[tag + '_detached'] = { form: el.form, willValidate: el.willValidate };
  }

  // fieldset.elements
  const fs = document.createElement('fieldset');
  fs.innerHTML = '<input name=a><select name=b></select><div><button name=c></button></div><output name=d></output>';
  out.fieldset_elements = {
    ctor: fs.elements.constructor.name,
    length: fs.elements.length,
    names: Array.from(fs.elements, (e) => e.tagName + ':' + e.name).join(','),
    live_before: fs.elements.length,
  };
  fs.appendChild(document.createElement('textarea'));
  out.fieldset_elements.live_after = fs.elements.length;
  out.fieldset_elements.same_object = fs.elements === fs.elements;

  // output.value / defaultValue
  const o = document.createElement('output');
  const seq = [];
  const snap = (label) => seq.push(`${label}: value=${JSON.stringify(o.value)} default=${JSON.stringify(o.defaultValue)} text=${JSON.stringify(o.textContent)}`);
  snap('fresh');
  o.textContent = 'text';
  snap('textContent=text');
  o.defaultValue = 'dv';
  snap('defaultValue=dv');
  o.value = 'v';
  snap('value=v');
  o.defaultValue = 'dv2';
  snap('defaultValue=dv2');
  o.textContent = 'text2';
  snap('textContent=text2');
  const o2 = document.createElement('output');
  o2.value = 'v';
  seq.push(`fresh-then-value: default=${JSON.stringify(o2.defaultValue)} html=${JSON.stringify(o2.innerHTML)}`);
  out.output_value = seq;

  // object's document accessors, with no data and with an about:blank data.
  const ob = document.createElement('object');
  out.object_docs_detached = {
    contentDocument: String(ob.contentDocument),
    contentWindow: String(ob.contentWindow),
    getSVGDocument: String(ob.getSVGDocument()),
    getSVGDocument_length: ob.getSVGDocument.length,
  };
  document.body.appendChild(ob);
  out.object_docs_attached = {
    contentDocument: String(ob.contentDocument),
    contentWindow: String(ob.contentWindow),
  };

  // Arities, which a shape check reads straight off the function object.
  const arity = {};
  for (const [name, iface] of [['fieldset', HTMLFieldSetElement], ['output', HTMLOutputElement], ['object', HTMLObjectElement], ['table', HTMLTableElement]]) {
    for (const k of Object.getOwnPropertyNames(iface.prototype)) {
      const d = Object.getOwnPropertyDescriptor(iface.prototype, k);
      if (typeof d.value === 'function' && k !== 'constructor') arity[name + '.' + k] = d.value.length;
    }
  }
  out.arity = arity;

  return JSON.stringify(out);
})()
