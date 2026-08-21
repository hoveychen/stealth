// The value sanitization algorithm: what a type does to a value it cannot
// represent. `probe-input-value.js` established the four value *modes*; this
// asks the next question, which is per-type parsing. Chrome reads a "TOK"
// assigned to type=number back as "", to type=color as "#000000", and to
// type=range as the midpoint -- three different flavours of "no".
//
// Every cell is `type` x `assigned value` -> what .value reads back, so the
// output is a table to implement against rather than a list of verdicts.
(() => {
  const out = {};

  // One row per (type, input). Kept flat and string-keyed so the two engines
  // diff cleanly even when one of them throws.
  const CASES = {
    // Numbers: floating point, so exponent and sign forms matter.
    number: ['', ' ', 'TOK', '12abc', '12', '12.5', '-3', '+3', '1e3', '1E3', '.5', '5.', '0012',
      '12 ', ' 12', '1,000', 'Infinity', 'NaN', '0x10', '1_000'],
    // Colors: the spec only accepts the 7-character lowercase hex form.
    color: ['', 'TOK', '#abc', '#AABBCC', '#aabbcc', 'red', 'rgb(1,2,3)', '#aabbccdd', 'aabbcc',
      '#AABBCC ', 'transparent'],
    // Range clamps rather than rejects, so min/max/step change the answer.
    range: ['', 'TOK', '5', '-5', '105', '50.7', '1e1'],
    // Dates and times: fixed formats, no leniency.
    date: ['', 'TOK', '2026-08-20', '2026-8-20', '2026-08-20T10:00', '20260820', '2026-13-01',
      '2026-02-30', '0000-01-01', '2026-08-20 '],
    time: ['', 'TOK', '10:00', '10:00:00', '10:00:00.5', '1:00', '25:00', '10:60', '10'],
    month: ['', 'TOK', '2026-08', '2026-8', '2026-13', '2026-08-20'],
    week: ['', 'TOK', '2026-W01', '2026-W1', '2026-W54', '2026-W00', '2026-08'],
    'datetime-local': ['', 'TOK', '2026-08-20T10:00', '2026-08-20 10:00', '2026-08-20T10:00:00',
      '2026-08-20T25:00', '2026-08-20'],
    // The controls: value mode keeps whatever it is given, including whitespace.
    text: ['', ' ', 'TOK', '  pad  ', 'a\nb', 'a\tb'],
    // Except these two, which strip newlines and tabs per the spec.
    email: ['', 'TOK', ' pad ', 'a\nb', 'a\tb', 'a@b.c'],
    url: ['', 'TOK', ' pad ', 'a\nb', 'a\tb', 'https://x.test/'],
    password: ['', 'TOK', 'a\nb'],
    hidden: ['', 'TOK', 'a\nb', '  pad  '],
  };

  const show = (s) => JSON.stringify(s);
  for (const [type, values] of Object.entries(CASES)) {
    for (const v of values) {
      const key = `${type}__${show(v)}`;
      try {
        const i = document.createElement('input');
        i.setAttribute('type', type);
        i.value = v;
        out[key] = `prop=${show(i.value)} attr=${show(i.getAttribute('value'))}`;
      } catch (e) {
        out[key] = `ERR ${e.name}`;
      }
    }
  }

  // The same values arriving as the content attribute rather than the property.
  // In value mode the attribute is the default, so this is the other direction
  // through the same sanitizer.
  for (const type of ['number', 'color', 'range', 'date', 'time', 'month', 'week', 'datetime-local']) {
    for (const v of ['TOK', '12', '2026-08-20', '#aabbcc']) {
      const key = `viaAttr_${type}__${show(v)}`;
      try {
        const i = document.createElement('input');
        i.setAttribute('type', type);
        i.setAttribute('value', v);
        out[key] = `prop=${show(i.value)} default=${show(i.defaultValue)}`;
      } catch (e) {
        out[key] = `ERR ${e.name}`;
      }
    }
  }

  // Range's clamp depends on min/max/step, which is the part that is arithmetic
  // rather than parsing.
  const rangeCase = (attrs, v) => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    for (const [k, val] of Object.entries(attrs)) i.setAttribute(k, val);
    i.value = v;
    return `prop=${show(i.value)}`;
  };
  out['range_default_noAssign'] = rangeCase({}, '50');
  out['range_bare'] = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    return `prop=${show(i.value)}`;
  })();
  out['range_min10_max20_assign5'] = rangeCase({ min: '10', max: '20' }, '5');
  out['range_min10_max20_assign25'] = rangeCase({ min: '10', max: '20' }, '25');
  out['range_min10_max20_bare'] = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    i.setAttribute('min', '10');
    i.setAttribute('max', '20');
    return `prop=${show(i.value)}`;
  })();
  out['range_step5_assign7'] = rangeCase({ min: '0', max: '20', step: '5' }, '7');
  out['range_maxBelowMin'] = rangeCase({ min: '20', max: '10' }, '15');

  // Number's min/max do NOT clamp -- only range does. Worth pinning so the
  // implementation does not over-generalize.
  out['number_min10_assign5'] = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'number');
    i.setAttribute('min', '10');
    i.value = '5';
    return `prop=${show(i.value)} valid=${i.validity ? i.validity.rangeUnderflow : 'n/a'}`;
  })();

  return { href: location.href, out };
})()
