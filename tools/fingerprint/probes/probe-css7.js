// Typed OM behaviour probe (batch 7). Shape lives in probe-css1.js; this one
// measures what the constructors accept, what the accessors hand back, how the
// values stringify and how a style map decides which subclass to return.
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${String(e.message).slice(0, 90)}`;
    }
  }
  // brand + stringification of any Typed OM value
  const B = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return '<undefined>';
    const c = v.constructor && v.constructor.name;
    let s;
    try { s = String(v); } catch (e) { s = `<toString ${e.name}>`; }
    return `${c}|${s}`;
  };
  const U = (n, u) => new CSSUnitValue(n, u);

  // ---- construction ----------------------------------------------------
  T('newStyleValue', () => B(new CSSStyleValue()));
  T('newNumericValue', () => B(new CSSNumericValue()));
  T('newImageValue', () => B(new CSSImageValue()));
  T('newNumericArray', () => B(new CSSNumericArray()));
  T('newMathValue', () => B(new CSSMathValue()));
  T('newTransformComponent', () => B(new CSSTransformComponent()));
  T('newStylePropertyMap', () => B(new StylePropertyMap()));
  T('newStylePropertyMapRO', () => B(new StylePropertyMapReadOnly()));

  T('keyword', () => B(new CSSKeywordValue('auto')));
  T('keywordEmpty', () => B(new CSSKeywordValue('')));
  T('keywordNoArg', () => B(new CSSKeywordValue()));
  T('keywordNumber', () => B(new CSSKeywordValue(5)));
  T('keywordSet', () => { const k = new CSSKeywordValue('auto'); k.value = 'none'; return B(k); });
  T('keywordSetEmpty', () => { const k = new CSSKeywordValue('auto'); k.value = ''; return B(k); });

  T('unitPx', () => B(U(5, 'px')));
  T('unitNumber', () => B(U(5, 'number')));
  T('unitPercent', () => B(U(50, 'percent')));
  T('unitDeg', () => B(U(90, 'deg')));
  T('unitBogus', () => B(U(5, 'bogus')));
  T('unitEmpty', () => B(U(5, '')));
  T('unitUpper', () => B(U(5, 'PX')));
  T('unitNoArgs', () => B(new CSSUnitValue()));
  T('unitNaN', () => B(U(NaN, 'px')));
  T('unitInf', () => B(U(Infinity, 'px')));
  T('unitStringNum', () => B(U('7', 'px')));
  T('unitFloat', () => B(U(1.5, 'px')));
  T('unitNegZero', () => B(U(-0, 'px')));
  T('unitSetValue', () => { const u = U(5, 'px'); u.value = 9; return B(u); });
  T('unitSetUnit', () => { const u = U(5, 'px'); try { u.unit = 'em'; } catch (e) { return `setter threw ${e.name}`; } return B(u); });
  T('unitUnitOf', () => [U(1, 'px').unit, U(1, 'number').unit, U(1, 'percent').unit, U(1, 'deg').unit, U(1, 'em').unit].join(','));

  T('varRef', () => { const v = new CSSVariableReferenceValue('--x'); return `${B(v)} variable=${v.variable} fallback=${B(v.fallback)}`; });
  T('varRefFallback', () => { const v = new CSSVariableReferenceValue('--x', new CSSUnparsedValue(['1px'])); return `${B(v)} fallback=${B(v.fallback)}`; });
  T('varRefBadName', () => B(new CSSVariableReferenceValue('x')));
  T('varRefNoArg', () => B(new CSSVariableReferenceValue()));
  T('varRefSet', () => { const v = new CSSVariableReferenceValue('--x'); v.variable = '--y'; return v.variable; });
  T('varRefSetBad', () => { const v = new CSSVariableReferenceValue('--x'); v.variable = 'y'; return v.variable; });

  T('unparsed', () => { const u = new CSSUnparsedValue(['a', ' ', 'b']); return `${B(u)} len=${u.length} 0=${JSON.stringify(u[0])}`; });
  T('unparsedEmpty', () => { const u = new CSSUnparsedValue([]); return `${B(u)} len=${u.length}`; });
  T('unparsedNoArg', () => { const u = new CSSUnparsedValue(); return `${B(u)} len=${u.length}`; });
  T('unparsedWithVar', () => { const u = new CSSUnparsedValue(['calc(', new CSSVariableReferenceValue('--x'), ')']); return `${B(u)} len=${u.length} 1=${B(u[1])}`; });
  T('unparsedIter', () => [...new CSSUnparsedValue(['a', 'b'])].map(B).join(' ; '));
  T('unparsedEntries', () => JSON.stringify([...new CSSUnparsedValue(['a', 'b']).entries()]));
  T('unparsedKeys', () => JSON.stringify([...new CSSUnparsedValue(['a', 'b']).keys()]));
  T('unparsedIndexSet', () => { const u = new CSSUnparsedValue(['a', 'b']); u[0] = 'z'; return `${B(u)} 0=${u[0]}`; });
  T('unparsedOwnKeys', () => JSON.stringify(Object.getOwnPropertyNames(new CSSUnparsedValue(['a', 'b']))));

  // ---- math ------------------------------------------------------------
  T('mathNegate', () => { const m = new CSSMathNegate(U(5, 'px')); return `${B(m)} op=${m.operator} value=${B(m.value)}`; });
  T('mathNegateNumber', () => B(new CSSMathNegate(3)));
  T('mathInvert', () => { const m = new CSSMathInvert(U(5, 'px')); return `${B(m)} op=${m.operator} value=${B(m.value)}`; });
  T('mathSum', () => { const m = new CSSMathSum(U(1, 'px'), U(2, 'em')); return `${B(m)} op=${m.operator} values=${B(m.values)} len=${m.values.length} 0=${B(m.values[0])}`; });
  T('mathSumEmpty', () => B(new CSSMathSum()));
  T('mathSumOne', () => B(new CSSMathSum(U(1, 'px'))));
  T('mathProduct', () => { const m = new CSSMathProduct(U(2, 'px'), 3); return `${B(m)} op=${m.operator} 0=${B(m.values[0])} 1=${B(m.values[1])}`; });
  T('mathMin', () => { const m = new CSSMathMin(U(1, 'px'), U(2, 'px')); return `${B(m)} op=${m.operator}`; });
  T('mathMax', () => { const m = new CSSMathMax(U(1, 'px'), U(2, 'px')); return `${B(m)} op=${m.operator}`; });
  T('mathClamp', () => { const m = new CSSMathClamp(U(1, 'px'), U(2, 'px'), U(3, 'px')); return `${B(m)} op=${m.operator} l=${B(m.lower)} v=${B(m.value)} u=${B(m.upper)}`; });
  T('mathClampMixed', () => B(new CSSMathClamp(U(1, 'px'), U(2, 'em'), U(3, 'px'))));
  T('mathSumIncompatible', () => B(new CSSMathSum(U(1, 'px'), U(2, 'deg'))));
  T('mathNumericArrayIter', () => [...new CSSMathSum(U(1, 'px'), U(2, 'em')).values].map(B).join(' ; '));
  T('mathNumericArrayForEach', () => { const a = []; new CSSMathSum(U(1, 'px'), U(2, 'em')).values.forEach((v, i) => a.push(`${i}:${B(v)}`)); return a.join(' ; '); });
  T('mathNested', () => B(new CSSMathSum(new CSSMathProduct(U(2, 'px'), 3), U(1, 'em'))));

  // ---- arithmetic on CSSNumericValue ----------------------------------
  T('addSameUnit', () => B(U(1, 'px').add(U(2, 'px'))));
  T('addNumberArg', () => B(U(1, 'number').add(2)));
  T('addDifferentUnit', () => B(U(1, 'px').add(U(2, 'em'))));
  T('addIncompatible', () => B(U(1, 'px').add(U(2, 'deg'))));
  T('addMulti', () => B(U(1, 'px').add(U(2, 'px'), U(3, 'px'))));
  T('addNoArgs', () => B(U(1, 'px').add()));
  T('subSameUnit', () => B(U(5, 'px').sub(U(2, 'px'))));
  T('mulNumber', () => B(U(5, 'px').mul(2)));
  T('mulUnit', () => B(U(5, 'px').mul(U(2, 'px'))));
  T('divNumber', () => B(U(6, 'px').div(2)));
  T('divZero', () => B(U(6, 'px').div(0)));
  T('minSame', () => B(U(1, 'px').min(U(2, 'px'))));
  T('maxSame', () => B(U(1, 'px').max(U(2, 'px'))));
  T('equalsTrue', () => U(1, 'px').equals(U(1, 'px')));
  T('equalsFalse', () => U(1, 'px').equals(U(2, 'px')));
  T('equalsUnit', () => U(1, 'px').equals(U(1, 'em')));
  T('equalsMulti', () => U(1, 'px').equals(U(1, 'px'), U(1, 'px')));
  T('equalsNone', () => U(1, 'px').equals());
  T('toSameUnit', () => B(U(1, 'px').to('px')));
  T('toCm', () => B(U(96, 'px').to('cm')));
  T('toIn', () => B(U(96, 'px').to('in')));
  T('toMm', () => B(U(96, 'px').to('mm')));
  T('toPt', () => B(U(96, 'px').to('pt')));
  T('toPc', () => B(U(96, 'px').to('pc')));
  T('toQ', () => B(U(96, 'px').to('q')));
  T('degToRad', () => B(U(180, 'deg').to('rad')));
  T('degToTurn', () => B(U(180, 'deg').to('turn')));
  T('degToGrad', () => B(U(180, 'deg').to('grad')));
  T('sToMs', () => B(U(1, 's').to('ms')));
  T('hzTokHz', () => B(U(1000, 'hz').to('khz')));
  T('dpiToDpcm', () => B(U(96, 'dpi').to('dpcm')));
  T('toIncompatible', () => B(U(1, 'px').to('deg')));
  T('toBogus', () => B(U(1, 'px').to('bogus')));
  T('toEm', () => B(U(1, 'em').to('em')));
  T('toSumSingle', () => { const s = U(1, 'px').toSum(); return `${B(s)} 0=${B(s.values[0])}`; });
  T('toSumWithUnits', () => { const s = U(1, 'px').toSum('px', 'em'); return `${B(s)} len=${s.values.length} 0=${B(s.values[0])} 1=${B(s.values[1])}`; });
  T('toSumOfSum', () => B(new CSSMathSum(U(1, 'px'), U(2, 'px')).toSum()));
  T('typePx', () => JSON.stringify(U(1, 'px').type()));
  T('typeNumber', () => JSON.stringify(U(1, 'number').type()));
  T('typePercent', () => JSON.stringify(U(1, 'percent').type()));
  T('typeDeg', () => JSON.stringify(U(1, 'deg').type()));
  T('typeS', () => JSON.stringify(U(1, 's').type()));
  T('typeHz', () => JSON.stringify(U(1, 'hz').type()));
  T('typeDpi', () => JSON.stringify(U(1, 'dpi').type()));
  T('typeFr', () => JSON.stringify(U(1, 'fr').type()));
  T('typeProduct', () => JSON.stringify(new CSSMathProduct(U(1, 'px'), U(2, 'px')).type()));

  T('parseNumber', () => B(CSSNumericValue.parse('42')));
  T('parsePx', () => B(CSSNumericValue.parse('42px')));
  T('parseCalc', () => B(CSSNumericValue.parse('calc(1px + 2px)')));
  T('parseCalcMixed', () => B(CSSNumericValue.parse('calc(1px + 2em)')));
  T('parseKeyword', () => B(CSSNumericValue.parse('auto')));
  T('parseSpaces', () => B(CSSNumericValue.parse('  10px  ')));
  T('parsePercent', () => B(CSSNumericValue.parse('10%')));

  T('styleValueParse', () => B(CSSStyleValue.parse('width', '10px')));
  T('styleValueParseKeyword', () => B(CSSStyleValue.parse('display', 'block')));
  T('styleValueParseColor', () => B(CSSStyleValue.parse('color', 'red')));
  T('styleValueParseTransform', () => B(CSSStyleValue.parse('transform', 'translate(1px, 2px)')));
  T('styleValueParseBad', () => B(CSSStyleValue.parse('width', 'notalength')));
  T('styleValueParseBadProp', () => B(CSSStyleValue.parse('nope', '1px')));
  T('styleValueParseAll', () => CSSStyleValue.parseAll('margin', '1px').map(B).join(' ; '));
  T('styleValueParseAllList', () => CSSStyleValue.parseAll('transition-property', 'color, width').map(B).join(' ; '));

  // ---- transforms ------------------------------------------------------
  T('translate2', () => { const t = new CSSTranslate(U(1, 'px'), U(2, 'px')); return `${B(t)} x=${B(t.x)} y=${B(t.y)} z=${B(t.z)} is2D=${t.is2D}`; });
  T('translate3', () => { const t = new CSSTranslate(U(1, 'px'), U(2, 'px'), U(3, 'px')); return `${B(t)} is2D=${t.is2D}`; });
  T('translateBadUnit', () => B(new CSSTranslate(U(1, 'deg'), U(2, 'px'))));
  T('translatePercent', () => B(new CSSTranslate(U(10, 'percent'), U(2, 'px'))));
  T('translateSetIs2D', () => { const t = new CSSTranslate(U(1, 'px'), U(2, 'px')); t.is2D = false; return `${B(t)} is2D=${t.is2D}`; });
  T('translateSetZ', () => { const t = new CSSTranslate(U(1, 'px'), U(2, 'px')); t.z = U(5, 'px'); return `${B(t)} is2D=${t.is2D}`; });
  T('rotate1', () => { const r = new CSSRotate(U(45, 'deg')); return `${B(r)} angle=${B(r.angle)} x=${B(r.x)} y=${B(r.y)} z=${B(r.z)} is2D=${r.is2D}`; });
  T('rotate4', () => { const r = new CSSRotate(1, 2, 3, U(45, 'deg')); return `${B(r)} is2D=${r.is2D}`; });
  T('rotateBad', () => B(new CSSRotate(U(45, 'px'))));
  T('scale2', () => { const s = new CSSScale(2, 3); return `${B(s)} x=${B(s.x)} y=${B(s.y)} z=${B(s.z)} is2D=${s.is2D}`; });
  T('scale3', () => { const s = new CSSScale(2, 3, 4); return `${B(s)} is2D=${s.is2D}`; });
  T('scaleUnit', () => B(new CSSScale(U(2, 'number'), U(3, 'number'))));
  T('scaleBadUnit', () => B(new CSSScale(U(2, 'px'), 3)));
  T('skew', () => { const s = new CSSSkew(U(1, 'deg'), U(2, 'deg')); return `${B(s)} ax=${B(s.ax)} ay=${B(s.ay)} is2D=${s.is2D}`; });
  T('skewX', () => { const s = new CSSSkewX(U(1, 'deg')); return `${B(s)} ax=${B(s.ax)} is2D=${s.is2D}`; });
  T('skewY', () => { const s = new CSSSkewY(U(1, 'deg')); return `${B(s)} ay=${B(s.ay)} is2D=${s.is2D}`; });
  T('skewBad', () => B(new CSSSkew(U(1, 'px'), U(2, 'deg'))));
  T('perspective', () => { const p = new CSSPerspective(U(10, 'px')); return `${B(p)} length=${B(p.length)} is2D=${p.is2D}`; });
  T('perspectiveKeyword', () => B(new CSSPerspective(new CSSKeywordValue('none'))));
  T('perspectiveBad', () => B(new CSSPerspective(U(10, 'deg'))));
  T('matrixComponent', () => { const m = new CSSMatrixComponent(new DOMMatrix()); return `${B(m)} is2D=${m.is2D} matrix=${m.matrix.constructor.name}`; });
  T('matrixComponent3D', () => B(new CSSMatrixComponent(new DOMMatrix([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))));
  T('matrixComponentOpts', () => { const m = new CSSMatrixComponent(new DOMMatrix(), { is2D: false }); return `${B(m)} is2D=${m.is2D}`; });
  T('matrixComponentBad', () => B(new CSSMatrixComponent(1)));

  T('transformValue', () => { const t = new CSSTransformValue([new CSSTranslate(U(1, 'px'), U(2, 'px'))]); return `${B(t)} len=${t.length} is2D=${t.is2D} 0=${B(t[0])}`; });
  T('transformValueEmpty', () => B(new CSSTransformValue([])));
  T('transformValueNoArg', () => B(new CSSTransformValue()));
  T('transformValueMixed', () => { const t = new CSSTransformValue([new CSSTranslate(U(1, 'px'), U(2, 'px')), new CSSScale(2, 3)]); return `${B(t)} len=${t.length} is2D=${t.is2D}`; });
  T('transformValue3D', () => { const t = new CSSTransformValue([new CSSTranslate(U(1, 'px'), U(2, 'px'), U(3, 'px'))]); return `${B(t)} is2D=${t.is2D}`; });
  T('transformToMatrix', () => { const m = new CSSTransformValue([new CSSTranslate(U(1, 'px'), U(2, 'px'))]).toMatrix(); return `${m.constructor.name}|${m.toString()}|is2D=${m.is2D}`; });
  T('transformToMatrixScale', () => String(new CSSTransformValue([new CSSScale(2, 3)]).toMatrix()));
  T('transformToMatrixRotate', () => String(new CSSTransformValue([new CSSRotate(U(90, 'deg'))]).toMatrix()));
  T('transformToMatrixEm', () => { try { return String(new CSSTransformValue([new CSSTranslate(U(1, 'em'), U(2, 'px'))]).toMatrix()); } catch (e) { return `ERR ${e.name}`; } });
  T('transformIter', () => [...new CSSTransformValue([new CSSScale(2, 3)])].map(B).join(' ; '));
  T('transformIndexSet', () => { const t = new CSSTransformValue([new CSSScale(2, 3)]); t[0] = new CSSScale(4, 5); return B(t); });
  T('transformOwnKeys', () => JSON.stringify(Object.getOwnPropertyNames(new CSSTransformValue([new CSSScale(2, 3)]))));
  T('componentToMatrix', () => String(new CSSTranslate(U(1, 'px'), U(2, 'px')).toMatrix()));
  T('componentToMatrixRotate', () => String(new CSSRotate(U(90, 'deg')).toMatrix()));
  T('componentToMatrixSkewX', () => String(new CSSSkewX(U(45, 'deg')).toMatrix()));
  T('componentToMatrixPersp', () => String(new CSSPerspective(U(10, 'px')).toMatrix()));

  T('positionValue', () => { const p = new CSSPositionValue(U(1, 'px'), U(2, 'px')); return `${B(p)} x=${B(p.x)} y=${B(p.y)}`; });
  T('positionValueBad', () => B(new CSSPositionValue(U(1, 'deg'), U(2, 'px'))));

  // ---- style maps ------------------------------------------------------
  const el = document.createElement('div');
  document.body.appendChild(el);
  el.style.width = '10px';
  el.style.color = 'rgb(1, 2, 3)';
  el.style.display = 'block';
  el.style.opacity = '0.5';
  el.style.setProperty('--custom', 'hello');
  el.style.transform = 'translate(1px, 2px)';

  T('attrMapBrand', () => `${el.attributeStyleMap.constructor.name}|${String(el.attributeStyleMap)}`);
  T('attrMapSize', () => el.attributeStyleMap.size);
  T('attrMapGetWidth', () => B(el.attributeStyleMap.get('width')));
  T('attrMapGetColor', () => B(el.attributeStyleMap.get('color')));
  T('attrMapGetDisplay', () => B(el.attributeStyleMap.get('display')));
  T('attrMapGetOpacity', () => B(el.attributeStyleMap.get('opacity')));
  T('attrMapGetCustom', () => B(el.attributeStyleMap.get('--custom')));
  T('attrMapGetTransform', () => B(el.attributeStyleMap.get('transform')));
  T('attrMapGetMissing', () => B(el.attributeStyleMap.get('height')));
  T('attrMapGetBogus', () => B(el.attributeStyleMap.get('nope')));
  T('attrMapHas', () => `${el.attributeStyleMap.has('width')},${el.attributeStyleMap.has('height')}`);
  T('attrMapKeys', () => JSON.stringify([...el.attributeStyleMap.keys()]));
  T('attrMapEntries0', () => { const e = [...el.attributeStyleMap.entries()][0]; return `${e[0]} -> ${Array.isArray(e[1]) ? e[1].map(B).join('/') : B(e[1])}`; });
  T('attrMapGetAll', () => el.attributeStyleMap.getAll('width').map(B).join(' ; '));
  T('attrMapSet', () => { el.attributeStyleMap.set('height', U(3, 'px')); return `${el.style.height}|${B(el.attributeStyleMap.get('height'))}`; });
  T('attrMapSetString', () => { el.attributeStyleMap.set('top', '4px'); return el.style.top; });
  T('attrMapSetBadUnit', () => { try { el.attributeStyleMap.set('left', U(3, 'deg')); return el.style.left; } catch (e) { return `ERR ${e.name}`; } });
  T('attrMapSetBadProp', () => { try { el.attributeStyleMap.set('nope', '1px'); return 'ok'; } catch (e) { return `ERR ${e.name}`; } });
  T('attrMapSetKeyword', () => { el.attributeStyleMap.set('position', new CSSKeywordValue('absolute')); return el.style.position; });
  T('attrMapAppend', () => { try { el.attributeStyleMap.append('width', U(1, 'px')); return el.style.width; } catch (e) { return `ERR ${e.name}`; } });
  T('attrMapAppendList', () => { const d = document.createElement('div'); try { d.attributeStyleMap.append('transition-property', new CSSKeywordValue('color')); d.attributeStyleMap.append('transition-property', new CSSKeywordValue('width')); return d.style.transitionProperty; } catch (e) { return `ERR ${e.name}`; } });
  T('attrMapDelete', () => { const r = el.attributeStyleMap.delete('top'); return `${r === undefined ? '<undefined>' : r}|${el.style.top}`; });
  T('attrMapDeleteMissing', () => { const r = el.attributeStyleMap.delete('bottom'); return r === undefined ? '<undefined>' : r; });
  T('attrMapClear', () => { const d = document.createElement('div'); d.style.width = '1px'; d.attributeStyleMap.clear(); return `${JSON.stringify(d.getAttribute('style'))}|size=${d.attributeStyleMap.size}`; });
  T('attrMapSizeAfter', () => el.attributeStyleMap.size);
  T('attrMapCached', () => el.attributeStyleMap === el.attributeStyleMap);

  T('computedMapBrand', () => el.computedStyleMap().constructor.name);
  T('computedGetWidth', () => B(el.computedStyleMap().get('width')));
  T('computedGetDisplay', () => B(el.computedStyleMap().get('display')));
  T('computedGetColor', () => B(el.computedStyleMap().get('color')));
  T('computedGetOpacity', () => B(el.computedStyleMap().get('opacity')));
  T('computedGetZIndex', () => B(el.computedStyleMap().get('z-index')));
  T('computedGetFontFamily', () => B(el.computedStyleMap().get('font-family')));
  T('computedGetTransform', () => B(el.computedStyleMap().get('transform')));
  T('computedGetBorderWidth', () => B(el.computedStyleMap().get('border-top-width')));
  T('computedGetFlexGrow', () => B(el.computedStyleMap().get('flex-grow')));
  T('computedGetTransitionDuration', () => B(el.computedStyleMap().get('transition-duration')));
  T('computedGetLineHeight', () => B(el.computedStyleMap().get('line-height')));
  T('computedGetCustom', () => B(el.computedStyleMap().get('--custom')));

  // rule.styleMap
  const st = document.createElement('style');
  st.textContent = '#probe7 { width: 12px; color: red; }';
  document.head.appendChild(st);
  const rule = st.sheet.cssRules[0];
  T('ruleStyleMapBrand', () => rule.styleMap.constructor.name);
  T('ruleStyleMapGet', () => B(rule.styleMap.get('width')));
  T('ruleStyleMapSize', () => rule.styleMap.size);
  T('ruleStyleMapKeys', () => JSON.stringify([...rule.styleMap.keys()]));
  T('ruleStyleMapSet', () => { rule.styleMap.set('height', U(7, 'px')); return rule.cssText; });
  T('ruleStyleMapCached', () => rule.styleMap === rule.styleMap);

  return { href: location.href, out };
})()
