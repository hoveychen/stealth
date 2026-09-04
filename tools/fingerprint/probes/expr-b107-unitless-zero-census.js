(() => {
  const st = document.createElement('style');
  const rules = [];
  const add = (id, decl) => { rules.push('#' + id + '{' + decl + '}'); return id; };

  // transform functions, one per slot type
  const tf = [
    ['tf1', 'transform:rotate(0)'], ['tf2', 'transform:rotateX(0)'], ['tf3', 'transform:rotateZ(0)'],
    ['tf4', 'transform:rotate3d(1,1,1,0)'], ['tf5', 'transform:skew(0)'], ['tf6', 'transform:skewY(0)'],
    ['tf7', 'transform:translateX(0)'], ['tf8', 'transform:translate(0,0)'], ['tf9', 'transform:translateZ(0)'],
    ['tf10', 'transform:perspective(0)'], ['tf11', 'transform:scale(0)'], ['tf12', 'transform:matrix(1,0,0,1,0,0)'],
    ['tf13', '-webkit-transform:rotate(0)'],
  ];
  // standalone transform properties
  const sp = [['sp1', 'rotate:0'], ['sp2', 'translate:0'], ['sp3', 'scale:0']];
  // plain lengths
  const ln = [
    ['ln1', 'width:0'], ['ln2', 'margin-top:0'], ['ln3', 'top:0'], ['ln4', 'border-top-width:0'],
    ['ln5', 'padding-left:0'], ['ln6', 'letter-spacing:0'], ['ln7', 'text-indent:0'],
    ['ln8', 'outline-offset:0'], ['ln9', 'font-size:0'], ['ln10', 'flex-basis:0'],
  ];
  // angles / times outside transform
  const at = [['at1', 'transition-duration:0'], ['at2', 'animation-duration:0'],
              ['at3', 'background-image:linear-gradient(0,red,blue)']];
  // CONTROLS: unitless numbers that are legal and must NOT gain a unit
  const ctl = [['c1', 'line-height:0'], ['c2', 'z-index:0'], ['c3', 'flex-grow:0'],
               ['c4', 'opacity:0'], ['c5', 'order:0'], ['c6', 'font-weight:400']];

  const all = tf.concat(sp, ln, at, ctl);
  for (const [id, decl] of all) add(id, decl);
  st.textContent = rules.join('\n');
  document.head.appendChild(st);
  const out = {};
  const sheet = st.sheet;
  for (let i = 0; i < sheet.cssRules.length; i++) {
    const r = sheet.cssRules[i];
    out[all[i][1]] = r.style.cssText;
  }
  st.remove();
  return out;
})()
