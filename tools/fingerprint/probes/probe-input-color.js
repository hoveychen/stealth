// What type=color actually accepts. The spec's sanitizer only takes the
// 7-character lowercase hex "simple color", but Chrome runs the CSS color parser
// and serializes back to that form -- so short hex, alpha hex, named colors and
// the color functions all come through, with the alpha dropped.
//
// Three questions in one table: which spellings resolve, how whitespace and case
// are treated (they are *not* uniform -- a bare name tolerates none where hex
// does), and where the channel arithmetic rounds and clamps.
(() => {
  const out = {};
  const show = (s) => JSON.stringify(s);
  const read = (v) => {
    const i = document.createElement('input');
    i.setAttribute('type', 'color');
    i.value = v;
    return show(i.value);
  };

  const GROUPS = {
    // Hex, in all four lengths the CSS grammar has, plus near-misses.
    hex: ['#aabbcc', '#AABBCC', '#abc', '#ABC', '#abcd', '#aabbccdd', '#AABBCCDD',
      '#aabbc', '#aabbccc', '#gggggg', '#abg', 'aabbcc', 'abc', '', ' '],
    // Whitespace and case. A name is the one form that tolerates no padding.
    padding: ['red', 'red ', ' red', ' red ', '\tred', 'red\t', '\nred',
      '#aabbcc ', ' #aabbcc', ' #aabbcc ', '\t#aabbcc\t', '#abc ', ' #abc',
      'rgb(1,2,3) ', ' rgb(1,2,3)', ' rgb(1,2,3) '],
    // Names, and the keywords that are not absolute colours.
    named: ['RED', 'Red', 'rebeccapurple', 'ReBeCcApUrPlE', 'transparent',
      'currentcolor', 'inherit', 'initial', 'unset', 'var(--x)', 'notacolor'],
    // rgb(): legacy and modern syntax, clamping, percentages, rounding, alpha.
    rgb: ['rgb(1,2,3)', 'rgb(1, 2, 3)', 'rgb( 1 , 2 , 3 )', 'rgb(1 2 3)',
      'RGB(1,2,3)', 'RGBA(1,2,3,1)', 'rgb(255,255,255)',
      'rgba(1,2,3,0.5)', 'rgb(1,2,3,0.5)', 'rgb(1 2 3 / 0.5)', 'rgb(1 2 3 / 50%)',
      'rgba(1 2 3 / 0.5)', 'rgba(1,2,3)', 'rgb(1,2,3 , 0.5)',
      'rgb(256,0,0)', 'rgb(-1,0,0)', 'rgb(-1,255,0)', 'rgb(300,255,0)',
      'rgb(50%,0%,0%)', 'rgb(-1%,100%,0%)', 'rgb(50%,2,3)', 'rgb(1,50%,3)',
      'rgb(0.5,1.5,2.5)', 'rgb(2.5,3.5,4.5)', 'rgb(0.4,0.6,254.5)', 'rgb(1.5,2,3)',
      'rgb(none 2 3)', 'rgb(calc(1 + 1) 2 3)',
      'rgb(1,2)', 'rgb(1,2,3,)', 'rgb(1, 2 3)', 'rgb(1 2, 3)', 'rgb(1,2,3) x',
      'xrgb(1,2,3)'],
    // hsl(): hue wrapping and units, s/l clamping, alpha.
    hsl: ['hsl(0,100%,50%)', 'hsl(0 100% 50%)', 'hsl(120,100%,50%)',
      'hsl(240 100% 25%)', 'hsl(0,50%,50%)', 'hsl(0,0%,50%)', 'hsl(0,100%,0%)',
      'hsl(0,100%,100%)', 'hsl(30,60%,40%)', 'hsl(-120,100%,50%)',
      'hsl(480,100%,50%)', 'hsl(0,150%,50%)', 'hsl(0,-10%,50%)',
      'hsl(0deg,100%,50%)', 'hsl(0.5turn 100% 50%)',
      'hsla(0,100%,50%,0.5)', 'hsl(0 100% 50% / 0.5)'],
    // The colour-space functions, which need a conversion matrix rather than
    // sRGB arithmetic.
    spaces: ['hwb(0 0% 0%)', 'lab(50 0 0)', 'oklch(0.5 0.1 0)',
      'color(srgb 1 0 0)', 'color-mix(in srgb, red, blue)'],
  };

  for (const [group, values] of Object.entries(GROUPS)) {
    for (const v of values) out[`${group}__${show(v)}`] = read(v);
  }

  // The attribute path, where defaultValue keeps the raw text it was handed.
  for (const v of ['#abc', 'red', 'rgb(1,2,3)', '#aabbccdd', '#AABBCC ', 'notacolor']) {
    const i = document.createElement('input');
    i.setAttribute('type', 'color');
    i.setAttribute('value', v);
    out[`attr__${show(v)}`] = `${show(i.value)} default=${show(i.defaultValue)}`;
  }

  // An input never assigned at all still has a value: the sanitizer's answer for
  // the empty string.
  {
    const i = document.createElement('input');
    i.setAttribute('type', 'color');
    out.bare = `${show(i.value)} alpha=${'alpha' in i} colorSpace=${'colorSpace' in i}`;
  }

  return { href: location.href, out };
})()
