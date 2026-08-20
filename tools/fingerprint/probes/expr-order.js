(() => {
  const P = new DOMParser();
  const n = (s) => Array.from(P.parseFromString(s, 'text/xml').documentElement.attributes).map((a) => a.name);
  return {
    dflt_then_prefix: n('<root xmlns="urn:x" xmlns:s="urn:s"/>'),
    prefix_then_dflt: n('<root xmlns:s="urn:s" xmlns="urn:x"/>'),
    two_prefixes:     n('<root xmlns:a="urn:a" xmlns:b="urn:b"/>'),
    three_mixed:      n('<root xmlns:a="urn:a" xmlns="urn:x" xmlns:b="urn:b"/>'),
    decls_and_plain:  n('<root p="1" xmlns="urn:x" q="2" xmlns:s="urn:s" r="3"/>'),
  };
})()
