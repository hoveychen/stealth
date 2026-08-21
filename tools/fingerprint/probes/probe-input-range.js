// type=range is the one numeric type with no empty state: it clamps and snaps
// rather than rejecting, so every unrepresentable value still reads as a number.
//
// This maps the default, the clamp, the step ladder, and the part that is easy
// to get wrong -- the clamp re-runs on every min/max/step change, so the answer
// depends on the order the attributes arrive in. A bare `min=10 max=20` reads
// "20" and not the midpoint 15, because the value materialized at 50 first.
(() => {
  const out = {};
  const show = (s) => JSON.stringify(s);

  // Build in a given attribute order, optionally assign, then read.
  const ordered = (pairs, assign) => {
    const i = document.createElement('input');
    for (const [k, v] of pairs) i.setAttribute(k, v);
    if (assign !== undefined) i.value = assign;
    return show(i.value);
  };
  const R = (attrs, assign) => ordered([['type', 'range'], ...Object.entries(attrs)], assign);

  out.bare = R({});
  out.min10 = R({ min: '10' });
  out.max20 = R({ max: '20' });
  out.min10_max20 = R({ min: '10', max: '20' });
  out.max20_min10 = R({ max: '20', min: '10' });
  out.min10_max200 = R({ min: '10', max: '200' });
  out.minBad = R({ min: 'TOK' });
  out.maxBad = R({ max: 'TOK' });
  out.minBad_max20 = R({ min: 'TOK', max: '20' });
  out.negRange = R({ min: '-100', max: '-50' });
  out.negRange_assign0 = R({ min: '-100', max: '-50' }, '0');
  out.fracRange = R({ min: '0', max: '1' });

  // A max below the min collapses the range onto the min.
  out.maxBelowMin = R({ min: '20', max: '10' });
  out.maxBelowMin_assign15 = R({ min: '20', max: '10' }, '15');
  out.maxBelowMin_assign5 = R({ min: '20', max: '10' }, '5');
  out.maxBelowMin_assign99 = R({ min: '20', max: '10' }, '99');

  // Clamping an assigned value, and a value that arrived as the attribute.
  out.min10_max20_assign5 = R({ min: '10', max: '20' }, '5');
  out.min10_max20_assign25 = R({ min: '10', max: '20' }, '25');
  out.value_attr_5_min10 = R({ value: '5', min: '10' });
  out.min10_value_attr_5 = R({ min: '10', value: '5' });

  // Attribute order: type first materializes 50 and a later bound pulls it in;
  // min/max first means becoming a range centres on the range that exists.
  out.order_type_min_max = ordered([['type', 'range'], ['min', '10'], ['max', '20']]);
  out.order_min_max_type = ordered([['min', '10'], ['max', '20'], ['type', 'range']]);

  // The clamp is not gated on the dirty flag.
  out.dirty_then_max = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    i.value = '90';
    const before = i.value;
    i.setAttribute('max', '20');
    return `${before} -> ${i.value}`;
  })();

  // Bounds moving under a settled value, including one going away again.
  out.reclamp_sequence = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    const a = i.value;
    i.setAttribute('max', '20');
    const b = i.value;
    i.setAttribute('min', '30');
    const c = i.value;
    i.removeAttribute('max');
    return `${a} -> ${b} -> ${c} -> ${i.value}`;
  })();

  // The step ladder, anchored at min.
  out.step5_assign7 = R({ min: '0', max: '20', step: '5' }, '7');
  out.step5_assign7_5 = R({ min: '0', max: '20', step: '5' }, '7.5');
  out.step5_bare = R({ min: '0', max: '20', step: '5' });
  out.step5_bare_odd = R({ min: '0', max: '21', step: '5' });
  out.stepAny_assign7 = R({ min: '0', max: '20', step: 'any' }, '7.3');
  out.step0_assign7 = R({ min: '0', max: '20', step: '0' }, '7');
  out.stepNeg_assign7 = R({ min: '0', max: '20', step: '-5' }, '7');
  // A fractional ladder: 0 + 3 * 0.1 is 0.30000000000000004 in binary floating
  // point, and Chrome -- which holds the value in a decimal type -- reads "0.3".
  out.fracRange_step = R({ min: '0', max: '1', step: '0.1' }, '0.25');

  // Assignment re-serializes the number; the attribute path normalizes the
  // literal but keeps its exponential spelling and does *not* snap.
  for (const v of ['1e1', '1E1', '1e+1', '2e1', '1e2', '10.0', '010', '50.00',
    '12', '0.5', '0.30', '-0', '+50', '5.', '.5', 'TOK', '']) {
    const a = document.createElement('input');
    a.setAttribute('type', 'range');
    a.setAttribute('value', v);
    const b = document.createElement('input');
    b.setAttribute('type', 'range');
    b.value = v;
    out[`literal__${show(v)}`] = `attr=${show(a.value)} assign=${show(b.value)}`;
  }

  // ... and a bound moving afterwards does not re-serialize a value already in
  // range, so the exponential spelling survives.
  out.attr_1e1_then_max = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'range');
    i.setAttribute('value', '1e1');
    const before = i.value;
    i.setAttribute('max', '20');
    return `${before} -> ${i.value}`;
  })();

  // The contrast: type=number keeps whatever literal it was handed.
  out.number_keeps_literal = (() => {
    const i = document.createElement('input');
    i.setAttribute('type', 'number');
    i.value = '1e1';
    return show(i.value);
  })();

  return { href: location.href, out };
})()
