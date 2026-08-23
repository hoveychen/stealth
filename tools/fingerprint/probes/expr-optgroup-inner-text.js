// `<optgroup>` text, in and out of a `<select>`. The innerText walk here drops
// text directly inside `<select>` and `<optgroup>` alike; Chrome only drops the
// `<select>` half.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-optgroup-inner-text.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-optgroup-inner-text.js
(() => {
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const out = {};

  const loose = document.createElement('optgroup');
  loose.textContent = 'Toptgroup';
  document.body.appendChild(loose);
  out.looseOptgroupInnerText = loose.innerText;
  out.looseOptgroupDisplay = getComputedStyle(loose).display;

  const select = document.createElement('select');
  select.innerHTML = 'stray<optgroup label="G">grouptext<option>opt</option></optgroup>';
  document.body.appendChild(select);
  const og = select.querySelector('optgroup');
  out.selectInnerText = select.innerText;
  out.nestedOptgroupInnerText = og.innerText;
  out.nestedOptgroupTextContent = og.textContent;
  out.nestedOptionInnerText = select.querySelector('option').innerText;
  return JSON.stringify(out);
})()
