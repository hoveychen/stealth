(() => {
  const out = {};
  const host = document.createElement('div');
  host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
  document.body.appendChild(host);
  const probe = document.createElement('div');
  probe.id = 'selprobe';
  host.appendChild(probe);

  // `#selprobe, X { letter-spacing: 3px }`: 3px means the rule survived X,
  // normal means the whole rule was dropped because of it.
  const withList = (selector) => {
    const sheet = document.createElement('style');
    sheet.textContent = `#selprobe, ${selector} { letter-spacing: 3px }`;
    document.head.appendChild(sheet);
    const seen = getComputedStyle(probe).letterSpacing;
    sheet.remove();
    return seen;
  };

  const cases = [
    // Combinators and the basics, as controls.
    ['child', '.a > .b'], ['adjacent', '.a + .b'], ['sibling', '.a ~ .b'],
    ['descendant', '.a .b'], ['columnCombinator', '.a || .b'],
    // Selectors 4 logical groups.
    ['is', ':is(.a, .b)'], ['where', ':where(.a, .b)'], ['not', ':not(.a)'],
    ['notList', ':not(.a, .b)'], ['has', ':has(.a)'], ['hasRelative', ':has(> .a)'],
    ['nestedIs', ':is(:not(.a), .b)'],
    // Structural pseudo-classes.
    ['root', ':root'], ['empty', ':empty'], ['firstChild', ':first-child'],
    ['lastOfType', ':last-of-type'], ['onlyChild', ':only-child'],
    ['nthChildOf', ':nth-child(2n+1 of .a)'], ['nthChildEven', ':nth-child(even)'],
    ['nthLastChild', ':nth-last-child(3)'],
    // Form and state.
    ['checked', ':checked'], ['disabled', ':disabled'], ['required', ':required'],
    ['optional', ':optional'], ['invalid', ':invalid'], ['inRange', ':in-range'],
    ['placeholderShown', ':placeholder-shown'], ['readOnly', ':read-only'],
    ['indeterminate', ':indeterminate'], ['defaultPseudo', ':default'],
    ['autofill', ':autofill'], ['userValid', ':user-valid'], ['open', ':open'],
    // Links and interaction.
    ['anyLink', ':any-link'], ['localLink', ':local-link'], ['targetWithin', ':target-within'],
    ['focusVisible', ':focus-visible'], ['focusWithin', ':focus-within'],
    // Language, direction, definition, shadow.
    ['lang', ':lang(en)'], ['dir', ':dir(ltr)'], ['defined', ':defined'],
    ['host', ':host'], ['hostFn', ':host(.a)'], ['hostContext', ':host-context(.a)'],
    ['scope', ':scope'],
    // Attribute forms.
    ['attrExists', '[data-x]'], ['attrEq', '[data-x=y]'], ['attrQuoted', '[data-x="y"]'],
    ['attrCaseI', '[data-x="y" i]'], ['attrCaseS', '[data-x="y" s]'],
    ['attrDash', '[data-x|=y]'], ['attrTilde', '[data-x~=y]'],
    ['attrPrefix', '[data-x^=y]'], ['attrSuffix', '[data-x$=y]'], ['attrSubstr', '[data-x*=y]'],
    ['attrNs', '[*|data-x]'],
    // Namespaces and escapes.
    ['universalNs', '*|div'], ['escapedClass', '.a\\\\:b'], ['escapedHash', '#a\\\\.b'],
    ['unicodeEscape', '.\\\\30 a'],
    // Nesting, which a stylesheet can carry at top level in `&`-form.
    ['nestingAmp', 'div:is(&)'],
    // Functional pseudo-elements with arguments.
    ['highlightFn', '::highlight(x)'], ['viewTransitionGroup', '::view-transition-group(x)'],
    // Things that should be dropped, as the negative controls.
    ['unknownClass', ':nonsense-class'], ['unknownFn', ':nonsense-fn(x)'],
    ['badSyntax', '>>>'], ['unclosed', '[data-x'],
  ];
  for (const [label, selector] of cases) out[label] = withList(selector);
  host.remove();
  return out;
})()
