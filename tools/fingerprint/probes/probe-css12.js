// Property-name case across the Typed OM (batch 12). The CSSOM half is already
// case-insensitive on both engines (`style.getPropertyValue('WIDTH')`), so this
// one measures the maps and `CSSStyleValue.parse`: which spellings answer, which
// throw, and -- since the wording is the detectable half -- exactly what the
// messages echo when they do throw. A custom property name is the one thing that
// stays case-sensitive.
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${String(e.message).slice(0, 140)}`;
    }
  }
  const B = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return '<undefined>';
    const c = v.constructor && v.constructor.name;
    let s;
    try { s = String(v); } catch (e) { s = `<toString ${e.name}>`; }
    return `${c}|${s}`;
  };
  const L = (list) => (Array.isArray(list) ? `[${list.map(B).join(', ')}]` : B(list));
  // `name: message`, the pair the fixture asserts on.
  const E = (fn) => {
    try {
      fn();
    } catch (e) {
      return `${e.name}: ${e.message}`;
    }
    return null;
  };

  // A fresh element per case: set/delete mutate the style attribute.
  const fresh = () => {
    const d = document.createElement('div');
    d.setAttribute('style', 'width: 10px; display: block; --Case: 1px');
    document.documentElement.appendChild(d);
    return d;
  };
  const map = () => fresh().attributeStyleMap;

  // ---- attributeStyleMap: read ------------------------------------------
  T('getLower', () => B(map().get('width')));
  T('getUpper', () => B(map().get('WIDTH')));
  T('getMixed', () => B(map().get('Width')));
  T('getMixedDashed', () => B(map().get('Display')));
  T('getUpperPrefixed', () => B(map().get('-WEBKIT-TRANSFORM')));
  T('getUnknownUpper', () => E(() => map().get('BOGUS')));
  T('hasUpper', () => map().has('WIDTH'));
  T('hasUpperAbsent', () => map().has('HEIGHT'));
  T('hasUnknownUpper', () => E(() => map().has('BOGUS')));
  T('getAllUpper', () => L(map().getAll('WIDTH')));
  T('getAllUnknownUpper', () => E(() => map().getAll('BOGUS')));

  // A custom property name is case-sensitive on both halves of the map.
  T('getCustomExact', () => B(map().get('--Case')));
  T('getCustomLower', () => B(map().get('--case')));
  T('getCustomUpper', () => B(map().get('--CASE')));

  // ---- attributeStyleMap: write ----------------------------------------
  T('setUpper', () => {
    const d = fresh();
    d.attributeStyleMap.set('HEIGHT', '5px');
    return `${d.style.height}|${d.getAttribute('style')}`;
  });
  T('setUpperTyped', () => {
    const d = fresh();
    d.attributeStyleMap.set('HEIGHT', new CSSUnitValue(5, 'px'));
    return `${d.style.height}|${B(d.attributeStyleMap.get('height'))}`;
  });
  T('setUpperWrongType', () => E(() => map().set('WIDTH', new CSSUnitValue(3, 'deg'))));
  T('setLowerWrongType', () => E(() => map().set('width', new CSSUnitValue(3, 'deg'))));
  T('setUnknownUpper', () => E(() => map().set('BOGUS', '1px')));
  T('deleteUpper', () => {
    const d = fresh();
    d.attributeStyleMap.delete('WIDTH');
    return `${d.style.width}|${d.getAttribute('style')}`;
  });
  T('deleteUnknownUpper', () => E(() => map().delete('BOGUS')));
  T('deleteCustomLower', () => {
    const d = fresh();
    d.attributeStyleMap.delete('--case');
    return d.getAttribute('style');
  });
  T('appendUpper', () => E(() => map().append('WIDTH', '1px')));
  T('appendUnknownUpper', () => E(() => map().append('BOGUS', '1px')));
  T('appendCustomUpper', () => E(() => map().append('--Case', '1px')));

  // ---- computedStyleMap -----------------------------------------------
  T('computedGetUpper', () => B(fresh().computedStyleMap().get('DISPLAY')));
  T('computedGetMixed', () => B(fresh().computedStyleMap().get('Width')));
  T('computedGetUpperUnknown', () => E(() => fresh().computedStyleMap().get('BOGUS')));
  T('computedHasUpper', () => fresh().computedStyleMap().has('DISPLAY'));
  T('computedGetAllUpper', () => L(fresh().computedStyleMap().getAll('DISPLAY')));

  // ---- CSSStyleValue.parse --------------------------------------------
  T('parseUpper', () => B(CSSStyleValue.parse('WIDTH', '10px')));
  T('parseMixed', () => B(CSSStyleValue.parse('Width', '10px')));
  T('parseUpperKeyword', () => B(CSSStyleValue.parse('DISPLAY', 'BLOCK')));
  T('parseUpperRejected', () => E(() => CSSStyleValue.parse('WIDTH', 'notalength')));
  T('parseUpperUnknownProperty', () => E(() => CSSStyleValue.parse('BOGUS', '1px')));
  T('parseUpperCustom', () => B(CSSStyleValue.parse('--Case', '1px')));
  T('parseAllUpper', () => L(CSSStyleValue.parseAll('WIDTH', '10px')));
  T('parseAllUpperRejected', () => E(() => CSSStyleValue.parseAll('WIDTH', 'notalength')));
  T('parseAllUpperUnknown', () => E(() => CSSStyleValue.parseAll('BOGUS', '1px')));

  return out;
})();
