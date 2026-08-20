(() => {
  const NAMES = [
    // CSSOM rule hierarchy
    'StyleSheet','CSSStyleSheet','CSSRule','CSSStyleRule','CSSGroupingRule','CSSConditionRule',
    'CSSMediaRule','CSSSupportsRule','CSSContainerRule','CSSLayerBlockRule','CSSLayerStatementRule',
    'CSSImportRule','CSSPageRule','CSSNamespaceRule','CSSFontFaceRule','CSSFontPaletteValuesRule',
    'CSSCounterStyleRule','CSSPropertyRule','CSSKeyframesRule','CSSKeyframeRule',
    'CSSRuleList','CSSStyleDeclaration','StyleSheetList','MediaList',
    // Typed OM
    'CSSStyleValue','CSSKeywordValue','CSSUnitValue','CSSNumericValue','CSSUnparsedValue',
    'CSSVariableReferenceValue','CSSImageValue','CSSNumericArray','CSSMathValue','CSSMathSum',
    'CSSMathProduct','CSSMathNegate','CSSMathMin','CSSMathMax','CSSMathInvert','CSSMathClamp',
    'CSSTransformValue','CSSTransformComponent','CSSTranslate','CSSRotate','CSSScale','CSSSkew',
    'CSSSkewX','CSSSkewY','CSSPerspective','CSSMatrixComponent','CSSPositionValue',
    'StylePropertyMap','StylePropertyMapReadOnly',
    // CSS events + animations
    'TransitionEvent','AnimationEvent','MediaQueryListEvent','FontFaceSetLoadEvent',
    'CSSAnimation','CSSTransition','Animation','AnimationEffect','MediaQueryList',
  ];
  function desc(o, k) {
    const d = Object.getOwnPropertyDescriptor(o, k);
    if (!d) return '?';
    if ('value' in d) {
      const t = typeof d.value;
      return t === 'function' ? `m:${d.value.length}` : `v:${JSON.stringify(d.value)}`;
    }
    return `a:${d.get ? 'g' : ''}${d.set ? 's' : ''}`;
  }
  const out = {};
  for (const n of NAMES) {
    const C = window[n];
    if (typeof C === 'undefined') { out[n] = null; continue; }
    const p = C.prototype;
    const chain = [];
    let x = p;
    while (x) {
      const tag = Object.getOwnPropertyDescriptor(x, Symbol.toStringTag);
      chain.push(x === Object.prototype ? 'Object.prototype' : (tag ? tag.value : '?'));
      x = Object.getPrototypeOf(x);
    }
    out[n] = {
      arity: C.length,
      cname: C.name,
      chain,
      protoKeys: p ? Object.getOwnPropertyNames(p).map(k => `${k}=${desc(p, k)}`) : null,
      protoSyms: p ? Object.getOwnPropertySymbols(p).map(String) : null,
      staticKeys: Object.getOwnPropertyNames(C).filter(k => !['length','name','prototype'].includes(k))
        .map(k => `${k}=${desc(C, k)}`),
    };
  }
  return { href: location.href, out };
})()
