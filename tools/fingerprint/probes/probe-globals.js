// Every own property name on `window`, so the two engines' global surfaces can
// be diffed by name rather than by a detector's idea of which names matter.
// Names only -- values, descriptors and prototype shapes are what the probe-win*
// batches measure; this one answers "which globals exist at all".
//
// Run it the same way on both engines and, for Chrome, both with and without
// --headed: a headless Chrome is missing globals a headed one has, so a
// headless baseline turns those into phantom "we have it, Chrome does not"
// rows.
(() => {
  const names = Object.getOwnPropertyNames(window).sort();
  // A window own name that is a plain data property holding a function with a
  // prototype is an interface object -- the half a detector enumerates when it
  // asks "which APIs does this browser have".
  const constructors = names.filter((n) => {
    try {
      const d = Object.getOwnPropertyDescriptor(window, n);
      return !!d && 'value' in d && typeof d.value === 'function' &&
        Object.prototype.hasOwnProperty.call(d.value, 'prototype');
    } catch (e) {
      return false;
    }
  });
  const handlers = names.filter((n) => n.startsWith('on'));
  return {
    userAgent: navigator.userAgent,
    href: location.href,
    count: names.length,
    constructorCount: constructors.length,
    handlerCount: handlers.length,
    names: names.join(' '),
    constructors: constructors.join(' '),
  };
})();
