// What are Chrome's path-antialiasing coverage levels, exactly?
//
// expr-aa-coverage-curve.js found one triangle where Chrome used three partial
// values -- 64, 128, 191, so quarter steps -- against our fifteen in
// sixteenths. Three values from one shape is not enough to conclude "Chrome
// quantises to quarters": it could be that this triangle's edge happens to
// land on quarter boundaries, or that the level set changes with the angle.
// Before changing a rasteriser that every shape and all text goes through, the
// question is which.
//
// So: sweep many angles and curvatures and collect the UNION of the partial
// coverage values each arm produces. A fixed quantisation shows up as a small
// closed set that does not grow with the number of shapes; an analytic
// coverage shows up as a set that keeps filling in.
(() => {
  const out = {};
  const partials = (draw, size = 64) => {
    const ctx = new OffscreenCanvas(size, size).getContext('2d');
    ctx.fillStyle = '#000000';
    draw(ctx);
    const d = ctx.getImageData(0, 0, size, size).data;
    const s = new Set();
    for (let i = 3; i < d.length; i += 4) if (d[i] > 0 && d[i] < 255) s.add(d[i]);
    return s;
  };
  const union = (sets) => {
    const all = new Set();
    for (const s of sets) for (const v of s) all.add(v);
    return [...all].sort((a, b) => a - b);
  };

  // (1) Straight edges at many angles: a triangle whose apex walks around.
  const angles = [];
  for (let k = 0; k < 24; k++) {
    const a = (k / 24) * Math.PI * 2;
    angles.push(partials((ctx) => {
      ctx.beginPath();
      ctx.moveTo(32, 32);
      ctx.lineTo(32 + 28 * Math.cos(a), 32 + 28 * Math.sin(a));
      ctx.lineTo(32 + 28 * Math.cos(a + 0.35), 32 + 28 * Math.sin(a + 0.35));
      ctx.closePath();
      ctx.fill();
    }));
  }
  const angleSet = union(angles);
  out.angles_count = angleSet.length;
  out.angles_values = angleSet.join(',');

  // (2) Curves, where a rasteriser that flattens differently would show up.
  const curves = [];
  for (let r = 6; r <= 30; r += 2) {
    curves.push(partials((ctx) => {
      ctx.beginPath();
      ctx.arc(32, 32, r + 0.37, 0, Math.PI * 2);
      ctx.fill();
    }));
  }
  const curveSet = union(curves);
  out.curves_count = curveSet.length;
  out.curves_values = curveSet.join(',');

  // (3) Everything together: does the union keep growing?
  const all = union([...angles, ...curves]);
  out.union_count = all.length;
  out.union_values = all.join(',');

  // (4) A single near-horizontal edge swept in fine sub-pixel steps. If the
  // levels are a fixed quantisation, this walks a staircase; if coverage is
  // analytic, it walks smoothly.
  const stair = [];
  for (let f = 0; f < 16; f++) {
    const ctx = new OffscreenCanvas(64, 64).getContext('2d');
    ctx.fillStyle = '#000000';
    ctx.beginPath();
    // A very shallow wedge so row 32's coverage is set by the sub-pixel offset.
    ctx.moveTo(0, 32 + f / 16);
    ctx.lineTo(64, 32 + f / 16 + 0.001);
    ctx.lineTo(64, 64);
    ctx.lineTo(0, 64);
    ctx.closePath();
    ctx.fill();
    stair.push(ctx.getImageData(32, 32, 1, 1).data[3]);
  }
  out.shallow_sweep = stair.join(',');

  return out;
})()
