// Does reading the same live-collection member twice hand back the same object?
// Chrome caches the collection wrapper per (node, collection type), so `===`
// holds; an engine that builds a fresh wrapper per get answers false to a
// one-expression check no page would ever need but a fingerprint script can
// ask for free.
(() => {
  const d = document;
  const body = d.body;
  const div = d.createElement('div');
  div.innerHTML = '<span class=x></span><a href=#></a><a name=n></a><form><input name=i></form><table><tr><td></td></tr></table><select><option></option></select><fieldset><input></fieldset>';
  body.appendChild(div);
  const table = div.querySelector('table');
  const select = div.querySelector('select');
  const form = div.querySelector('form');
  const fs = div.querySelector('fieldset');
  const row = div.querySelector('tr');

  const cases = {
    'document.forms': () => d.forms,
    'document.images': () => d.images,
    'document.links': () => d.links,
    'document.anchors': () => d.anchors,
    'document.scripts': () => d.scripts,
    'document.embeds': () => d.embeds,
    'document.all': () => d.all,
    'document.styleSheets': () => d.styleSheets,
    'element.children': () => div.children,
    'element.classList': () => div.classList,
    'element.attributes': () => div.attributes,
    'node.childNodes': () => div.childNodes,
    'getElementsByTagName': () => d.getElementsByTagName('a'),
    'getElementsByClassName': () => d.getElementsByClassName('x'),
    'form.elements': () => form.elements,
    'fieldset.elements': () => fs.elements,
    'table.rows': () => table.rows,
    'table.tBodies': () => table.tBodies,
    'row.cells': () => row.cells,
    'select.options': () => select.options,
    'select.selectedOptions': () => select.selectedOptions,
    'navigator.plugins': () => navigator.plugins,
    'navigator.mimeTypes': () => navigator.mimeTypes,
  };

  const out = {};
  for (const [name, get] of Object.entries(cases)) {
    try {
      const a = get(), b = get();
      out[name] = { same: a === b, ctor: a && a.constructor ? a.constructor.name : String(a) };
    } catch (e) {
      out[name] = { same: 'threw', ctor: e.name };
    }
  }
  return JSON.stringify(out);
})()
