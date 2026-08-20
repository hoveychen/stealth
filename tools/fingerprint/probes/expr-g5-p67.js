(() => {
  const out = {};
  const p = new DOMParser();
  const bad = p.parseFromString('<a', 'text/xml');
  out.parsererror_serialized = new XMLSerializer().serializeToString(bad);
  out.parsererror_root_name = bad.documentElement.nodeName;
  out.parsererror_root_ns = bad.documentElement.namespaceURI;
  out.parsererror_attrs = Array.from(bad.documentElement.attributes).map((a) => [a.name, a.value]);

  // What XMLSerializer does with a hand-built element in a namespace whose
  // declaration is not an attribute.
  const made = document.implementation.createDocument('urn:x', 'Root');
  out.made_serialized = new XMLSerializer().serializeToString(made);
  out.made_attrs = Array.from(made.documentElement.attributes).map((a) => [a.name, a.value]);

  // Same shape as our synthetic parsererror string, round-tripped.
  const round = p.parseFromString('<parsererror xmlns="http://www.mozilla.org/newlayout/xml/parsererror.xml">error</parsererror>', 'text/xml');
  out.round_serialized = new XMLSerializer().serializeToString(round);
  out.round_attrs = Array.from(round.documentElement.attributes).map((a) => [a.name, a.value]);
  return out;
})()
