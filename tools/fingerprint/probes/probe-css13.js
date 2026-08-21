// The declaration side of the CSSOM: what a `style=` attribute reads back as.
// Two questions, both raised by probe-css12 and neither about property-name
// case (that half is done):
//
//   1. Which parts of a *value* get lowercased on the way in? `Color: RED`
//      reads back `color: red` in Chrome, but a font family, a custom ident and
//      a custom property's value keep the case they were written with -- so a
//      blanket lowercase would be as wrong as none at all.
//   2. Which operations rewrite the attribute text? Deleting a property that
//      was never there is a no-op in Chrome and the authored text survives
//      byte for byte, trailing semicolon and all.
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${String(e.message).slice(0, 120)}`;
    }
  }
  // A div carrying exactly the authored text, never touched by anything else.
  const withStyle = (text) => {
    const d = document.createElement('div');
    d.setAttribute('style', text);
    document.documentElement.appendChild(d);
    return d;
  };
  // cssText round trip: what the whole declaration serialises to.
  const round = (text) => withStyle(text).style.cssText;
  // one property's value, read back
  const value = (text, prop) => withStyle(text).style.getPropertyValue(prop);

  // ---- 1. value keyword case ------------------------------------------
  T('keywordDisplay', () => round('display: BLOCK'));
  T('keywordPosition', () => round('position: Absolute'));
  T('colorNamed', () => round('color: RED'));
  T('colorHex', () => round('color: #AABBCC'));
  T('colorFunc', () => round('color: RGB(1, 2, 3)'));
  T('colorFuncUpperArgs', () => round('background-color: RGBA(1, 2, 3, 0.5)'));
  T('lengthUnit', () => round('width: 10PX'));
  T('lengthUnitEm', () => round('width: 10EM'));
  T('lengthScientific', () => round('width: 1E2px'));
  T('transformFunc', () => round('transform: TranslateX(1PX)'));
  T('shorthandMargin', () => round('margin: 1PX 2Px'));
  T('important', () => round('color: RED !IMPORTANT'));
  T('cssWide', () => round('width: INHERIT'));
  T('cssWideUnset', () => round('display: Unset'));
  T('multiKeyword', () => round('overflow: HIDDEN Visible'));

  // The exceptions a blanket lowercase would break.
  T('fontFamilyIdent', () => round('font-family: MyOwnFont'));
  T('fontFamilyQuoted', () => round('font-family: "MyOwnFont"'));
  T('fontFamilyGeneric', () => round('font-family: SANS-SERIF'));
  T('animationName', () => round('animation-name: MyAnim'));
  T('gridArea', () => round('grid-area: MyArea'));
  T('counterReset', () => round('counter-reset: MyCounter 3'));
  T('contentString', () => round('content: "MiXeD"'));
  T('urlValue', () => round('background-image: URL(Foo/Bar.PNG)'));
  T('attrValue', () => round('content: ATTR(Data-X)'));
  T('varRef', () => round('width: VAR(--Foo)'));
  T('customPropValue', () => round('--Case: MiXeD Value'));
  T('customPropRead', () => value('--Case: MiXeD Value', '--Case'));

  // setProperty takes the same path as parsing the attribute?
  T('setPropertyKeyword', () => {
    const d = withStyle('');
    d.style.setProperty('color', 'RED');
    return `${d.style.color}|${d.getAttribute('style')}`;
  });
  T('setPropertyCamelApi', () => {
    const d = withStyle('');
    d.style.color = 'RED';
    return `${d.style.color}|${d.getAttribute('style')}`;
  });
  T('setPropertyFontFamily', () => {
    const d = withStyle('');
    d.style.setProperty('font-family', 'MyOwnFont');
    return d.style.fontFamily;
  });

  // ---- 2. what rewrites the attribute text -----------------------------
  const authored = 'width: 10px; display: block; --Case: 1px';
  T('untouched', () => withStyle(authored).getAttribute('style'));
  T('readOnlyGet', () => {
    const d = withStyle(authored);
    void d.style.width;
    void d.style.cssText;
    void d.style.length;
    return d.getAttribute('style');
  });
  T('removeAbsent', () => {
    const d = withStyle(authored);
    d.style.removeProperty('height');
    return d.getAttribute('style');
  });
  T('removeAbsentCustom', () => {
    const d = withStyle(authored);
    d.style.removeProperty('--nope');
    return d.getAttribute('style');
  });
  T('removeAbsentWrongCaseCustom', () => {
    const d = withStyle(authored);
    d.style.removeProperty('--case');
    return d.getAttribute('style');
  });
  T('removePresent', () => {
    const d = withStyle(authored);
    d.style.removeProperty('width');
    return d.getAttribute('style');
  });
  T('setSameValue', () => {
    const d = withStyle(authored);
    d.style.setProperty('width', '10px');
    return d.getAttribute('style');
  });
  T('setEmptyAbsent', () => {
    const d = withStyle(authored);
    d.style.setProperty('height', '');
    return d.getAttribute('style');
  });
  T('setBogusValue', () => {
    const d = withStyle(authored);
    d.style.setProperty('height', 'notalength');
    return d.getAttribute('style');
  });
  T('mapDeleteAbsent', () => {
    const d = withStyle(authored);
    d.attributeStyleMap.delete('height');
    return d.getAttribute('style');
  });
  T('mapGetOnly', () => {
    const d = withStyle(authored);
    void d.attributeStyleMap.get('width');
    return d.getAttribute('style');
  });
  T('cssTextRoundTripAttr', () => {
    const d = withStyle(authored);
    d.style.cssText = d.style.cssText;
    return d.getAttribute('style');
  });

  return out;
})();
