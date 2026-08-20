// Typed OM follow-ups: raw numeric precision vs. serialised precision, CSS
// ident escaping, the full error text of the throwing paths, and the subclass
// a style map picks for a wide sample of properties.
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${e.message}`;
    }
  }
  const U = (n, u) => new CSSUnitValue(n, u);
  const B = (v) => v === null ? 'null' : v === undefined ? '<undefined>' : `${v.constructor.name}|${String(v)}`;

  // raw value vs serialisation
  T('cmRaw', () => U(96, 'px').to('cm').value);
  T('radRaw', () => U(180, 'deg').to('rad').value);
  T('dpcmRaw', () => U(96, 'dpi').to('dpcm').value);
  T('qRaw', () => U(96, 'px').to('q').value);
  T('ptRaw', () => U(100, 'px').to('pt').value);
  T('cmRawStr', () => String(U(96, 'px').to('cm')));
  T('serialize', () => [
    1, 1.5, 0.5, 0.1, 1 / 3, 1e21, 1e-7, 123456789, 1234567.891, 0.000123456789,
    -2.5, 100, 1e100, 3.14159265358979, 2.0000001, 12345.6789,
  ].map((n) => `${n}=>${String(U(n, 'px'))}`).join(' '));
  T('serializeNumberUnit', () => [1, 1.5, 1 / 3].map((n) => String(U(n, 'number'))).join(' '));
  T('valueRoundTrip', () => { const u = U(1 / 3, 'px'); return `${u.value}|${String(u)}`; });

  // ident escaping
  T('idents', () => ['auto', 'a b', '5', '5x', '-x', '--x', '', 'a.b', 'ünï', 'A_B', 'a\\b']
    .map((s) => { try { return `${JSON.stringify(s)}=>${JSON.stringify(String(new CSSKeywordValue(s)))}`; } catch (e) { return `${JSON.stringify(s)}=>ERR ${e.name}`; } }).join(' '));
  T('keywordValueReadback', () => { const k = new CSSKeywordValue('5'); return `${JSON.stringify(k.value)}`; });

  // full error messages
  T('appendErr', () => { const d = document.createElement('div'); d.attributeStyleMap.append('width', U(1, 'px')); return 'no throw'; });
  T('appendListErr', () => { const d = document.createElement('div'); d.attributeStyleMap.append('transition-property', new CSSKeywordValue('color')); return `ok:${d.style.transitionProperty}`; });
  T('appendCustomErr', () => { const d = document.createElement('div'); d.attributeStyleMap.append('--x', '1'); return 'no throw'; });
  T('setBadUnitErr', () => { const d = document.createElement('div'); d.attributeStyleMap.set('left', U(3, 'deg')); return 'no throw'; });
  T('setBadPropErr', () => { const d = document.createElement('div'); d.attributeStyleMap.set('nope', '1px'); return 'no throw'; });
  T('setNoArgErr', () => { const d = document.createElement('div'); d.attributeStyleMap.set('width'); return 'no throw'; });
  T('deleteBadPropErr', () => { const d = document.createElement('div'); d.attributeStyleMap.delete('nope'); return 'no throw'; });
  T('hasBadProp', () => document.createElement('div').attributeStyleMap.has('nope'));
  T('getAllBadProp', () => document.createElement('div').attributeStyleMap.getAll('nope'));

  // CSSNumericArray / CSSUnparsedValue surface
  T('numericArrayOwnKeys', () => JSON.stringify(Object.getOwnPropertyNames(new CSSMathSum(U(1, 'px'), U(2, 'px')).values)));
  T('numericArrayIndexSet', () => { const a = new CSSMathSum(U(1, 'px'), U(2, 'px')).values; try { a[0] = U(9, 'px'); } catch (e) { return `ERR ${e.name}`; } return B(a[0]); });
  T('numericArrayOOB', () => String(new CSSMathSum(U(1, 'px')).values[5]));
  T('unparsedTwoStrings', () => JSON.stringify(String(new CSSUnparsedValue(['a', 'b']))));
  T('unparsedOneString', () => JSON.stringify(String(new CSSUnparsedValue(['a']))));
  T('unparsedTrim', () => JSON.stringify(String(new CSSUnparsedValue([' a ', 'b']))));
  T('unparsedOOB', () => String(new CSSUnparsedValue(['a'])[5]));
  T('unparsedForEach', () => { const a = []; new CSSUnparsedValue(['a', 'b']).forEach((v, i) => a.push(`${i}:${v}`)); return a.join(','); });
  T('varRefToString', () => JSON.stringify(String(new CSSVariableReferenceValue('--x'))));
  T('varRefInUnparsedFallback', () => JSON.stringify(String(new CSSUnparsedValue([new CSSVariableReferenceValue('--x', new CSSUnparsedValue(['red']))]))));

  // types
  T('typeSumMixed', () => JSON.stringify(new CSSMathSum(U(1, 'px'), U(2, 'em')).type()));
  T('typeSumPctLen', () => { try { return JSON.stringify(new CSSMathSum(U(1, 'px'), U(2, 'percent')).type()); } catch (e) { return `ERR ${e.name}: ${e.message}`; } });
  T('typeInvert', () => JSON.stringify(new CSSMathInvert(U(1, 'px')).type()));
  T('typeNegate', () => JSON.stringify(new CSSMathNegate(U(1, 'px')).type()));
  T('typeProductPxDeg', () => JSON.stringify(new CSSMathProduct(U(1, 'px'), U(2, 'deg')).type()));
  T('typeDppx', () => JSON.stringify(U(1, 'dppx').type()));
  T('typeX', () => { try { return JSON.stringify(U(1, 'x').type()); } catch (e) { return `ERR ${e.name}`; } });
  T('typeCqw', () => { try { return JSON.stringify(U(1, 'cqw').type()); } catch (e) { return `ERR ${e.name}`; } });
  T('unitAll', () => ['number', 'percent', 'em', 'ex', 'ch', 'ic', 'rem', 'lh', 'rlh', 'vw', 'vh', 'vi', 'vb', 'vmin', 'vmax', 'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax', 'cm', 'mm', 'q', 'in', 'pt', 'pc', 'px', 'deg', 'grad', 'rad', 'turn', 's', 'ms', 'hz', 'khz', 'dpi', 'dpcm', 'dppx', 'x', 'fr']
    .map((u) => { try { const v = U(1, u); return `${u}:${v.unit}:${JSON.stringify(v.type())}`; } catch (e) { return `${u}:ERR`; } }).join(' '));

  // arithmetic edge cases
  T('addPxPercent', () => B(U(1, 'px').add(U(2, 'percent'))));
  T('subDifferent', () => B(U(1, 'px').sub(U(2, 'em'))));
  T('mulSum', () => B(new CSSMathSum(U(1, 'px'), U(2, 'em')).mul(2)));
  T('addToSum', () => B(new CSSMathSum(U(1, 'px'), U(2, 'em')).add(U(3, 'px'))));
  T('addSumSum', () => B(new CSSMathSum(U(1, 'px'), U(2, 'em')).add(new CSSMathSum(U(3, 'px'), U(4, 'em')))));
  T('divSum', () => B(new CSSMathSum(U(1, 'px'), U(2, 'em')).div(2)));
  T('negateNegate', () => B(new CSSMathNegate(new CSSMathNegate(U(1, 'px')))));
  T('minMulti', () => B(U(1, 'px').min(U(2, 'em'), U(3, 'px'))));
  T('equalsSum', () => new CSSMathSum(U(1, 'px'), U(2, 'em')).equals(new CSSMathSum(U(1, 'px'), U(2, 'em'))));
  T('toSumMismatch', () => { try { return B(U(1, 'px').toSum('em')); } catch (e) { return `ERR ${e.name}: ${e.message}`; } });
  T('toSumNoUnits3', () => { const s = new CSSMathSum(U(1, 'px'), U(2, 'em'), U(3, 'px')).toSum(); return `${String(s)} len=${s.values.length}`; });
  T('toOfSum', () => { try { return B(new CSSMathSum(U(1, 'px'), U(2, 'px')).to('px')); } catch (e) { return `ERR ${e.name}`; } });
  T('mulString', () => { try { return B(U(2, 'px').mul('3')); } catch (e) { return `ERR ${e.name}: ${e.message}`; } });

  // parse
  T('parseVar', () => { try { return B(CSSNumericValue.parse('var(--x)')); } catch (e) { return `ERR ${e.name}`; } });
  T('parseNeg', () => B(CSSNumericValue.parse('-3.5em')));
  T('parseExp', () => B(CSSNumericValue.parse('1e2px')));
  T('parseMinMax', () => { try { return B(CSSNumericValue.parse('min(1px, 2px)')); } catch (e) { return `ERR ${e.name}`; } });
  T('parseEmpty', () => { try { return B(CSSNumericValue.parse('')); } catch (e) { return `ERR ${e.name}: ${e.message}`; } });
  T('parseCalcMul', () => { try { return B(CSSNumericValue.parse('calc(2px * 3)')); } catch (e) { return `ERR ${e.name}`; } });

  // transforms
  T('is2DSetters', () => ['CSSTranslate', 'CSSRotate', 'CSSScale', 'CSSSkew', 'CSSSkewX', 'CSSSkewY', 'CSSPerspective', 'CSSMatrixComponent'].map((n) => {
    let c;
    if (n === 'CSSTranslate') c = new CSSTranslate(U(1, 'px'), U(2, 'px'));
    else if (n === 'CSSRotate') c = new CSSRotate(U(45, 'deg'));
    else if (n === 'CSSScale') c = new CSSScale(2, 3);
    else if (n === 'CSSSkew') c = new CSSSkew(U(1, 'deg'), U(2, 'deg'));
    else if (n === 'CSSSkewX') c = new CSSSkewX(U(1, 'deg'));
    else if (n === 'CSSSkewY') c = new CSSSkewY(U(1, 'deg'));
    else if (n === 'CSSPerspective') c = new CSSPerspective(U(10, 'px'));
    else c = new CSSMatrixComponent(new DOMMatrix());
    const before = c.is2D;
    let after; try { c.is2D = !before; after = c.is2D; } catch (e) { after = `ERR ${e.name}`; }
    return `${n}:${before}->${after}:${String(c)}`;
  }).join(' | '));
  T('skewToMatrix', () => String(new CSSSkew(U(30, 'deg'), U(45, 'deg')).toMatrix()));
  T('skewYToMatrix', () => String(new CSSSkewY(U(45, 'deg')).toMatrix()));
  T('scale3dToMatrix', () => String(new CSSScale(2, 3, 4).toMatrix()));
  T('translate3dToMatrix', () => String(new CSSTranslate(U(1, 'px'), U(2, 'px'), U(3, 'px')).toMatrix()));
  T('rotate3dToMatrix', () => String(new CSSRotate(1, 0, 0, U(90, 'deg')).toMatrix()));
  T('perspToMatrix', () => String(new CSSPerspective(U(100, 'px')).toMatrix()));
  T('perspNoneToMatrix', () => { try { return String(new CSSPerspective(new CSSKeywordValue('none')).toMatrix()); } catch (e) { return `ERR ${e.name}`; } });
  T('matrixCompToMatrix', () => { const m = new DOMMatrix(); m.e = 5; const c = new CSSMatrixComponent(m); return `${String(c.toMatrix())}|same=${c.toMatrix() === m}|matrixSame=${c.matrix === m}`; });
  T('transformValueToMatrixMulti', () => String(new CSSTransformValue([new CSSTranslate(U(1, 'px'), U(2, 'px')), new CSSScale(2, 3)]).toMatrix()));
  T('transformValueLenAfterSet', () => { const t = new CSSTransformValue([new CSSScale(2, 3)]); try { t[1] = new CSSScale(4, 5); } catch (e) { return `ERR ${e.name}`; } return `len=${t.length}`; });
  T('rotateSetAngle', () => { const r = new CSSRotate(U(45, 'deg')); r.angle = U(90, 'deg'); return String(r); });
  T('rotateSetXYZ', () => { const r = new CSSRotate(U(45, 'deg')); r.x = 1; r.y = 1; return `${String(r)} is2D=${r.is2D}`; });
  T('perspSetLength', () => { const p = new CSSPerspective(U(10, 'px')); p.length = U(20, 'px'); return String(p); });
  T('matrixSetMatrix', () => { const c = new CSSMatrixComponent(new DOMMatrix()); c.matrix = new DOMMatrix('scale(2)'); return String(c); });

  // dispatch over a wide sample of properties
  const el = document.createElement('div');
  el.id = 'p8';
  document.body.appendChild(el);
  const props = ['width', 'height', 'display', 'position', 'color', 'background-color', 'opacity', 'z-index',
    'font-size', 'font-family', 'font-weight', 'line-height', 'margin-top', 'padding-left', 'border-top-width',
    'border-top-style', 'border-top-color', 'transform', 'transition-duration', 'transition-property',
    'animation-name', 'flex-grow', 'flex-basis', 'order', 'grid-template-columns', 'background-image',
    'content', 'cursor', 'overflow-x', 'visibility', 'white-space', 'letter-spacing', 'word-spacing',
    'text-align', 'vertical-align', 'rotate', 'scale', 'translate', 'aspect-ratio', 'inset-block-start'];
  T('computedDispatch', () => props.map((p) => {
    try { const v = el.computedStyleMap().get(p); return `${p}=${v === undefined ? 'undef' : v.constructor.name}(${String(v)})`; } catch (e) { return `${p}=ERR ${e.name}`; }
  }).join(' | '));
  T('inlineDispatch', () => {
    const d = document.createElement('div');
    const set = { width: '10px', color: 'red', display: 'inline', opacity: '.25', 'z-index': '3', margin: '1px', transform: 'scale(2)', 'font-family': 'a, b', content: '"x"', '--v': ' 1px ' };
    for (const [k, v] of Object.entries(set)) d.style.setProperty(k, v);
    return Object.keys(set).map((p) => {
      try { const v = d.attributeStyleMap.get(p); return `${p}=${v === undefined ? 'undef' : v.constructor.name}(${String(v)})`; } catch (e) { return `${p}=ERR ${e.name}`; }
    }).join(' | ');
  });
  T('inlineShorthandKeys', () => { const d = document.createElement('div'); d.style.margin = '1px'; return JSON.stringify([...d.attributeStyleMap.keys()]); });
  T('computedSize', () => el.computedStyleMap().size);
  T('computedIterFirst', () => { const e = [...el.computedStyleMap()][0]; return `${e[0]} -> ${e[1].map((v) => `${v.constructor.name}|${v}`).join('/')}`; });
  T('computedGetAllTransitionProp', () => el.computedStyleMap().getAll('transition-property').map(B).join(' ; '));
  T('computedHasCustom', () => el.computedStyleMap().has('--nope'));
  T('computedGetUnsetCustom', () => String(el.computedStyleMap().get('--nope')));

  return { href: location.href, out };
})()
