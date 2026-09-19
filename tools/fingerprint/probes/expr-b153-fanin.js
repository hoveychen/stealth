(async () => {
  const build = async (wire) => {
    const ctx = new OfflineAudioContext(1, 5000, 44100);
    const osc = ctx.createOscillator();
    osc.type = 'triangle';
    osc.frequency.value = 10000;
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -50; comp.knee.value = 40; comp.ratio.value = 12;
    comp.attack.value = 0; comp.release.value = 0.25;
    osc.connect(comp);
    wire(ctx, comp);
    osc.start(0);
    const buf = await ctx.startRendering();
    const ch = buf.getChannelData(0);
    let sum = 0;
    for (let i = ch.length - 500; i < ch.length; i++) sum += Math.abs(ch[i]);
    return sum;
  };
  const out = {};
  out.direct = await build((ctx, comp) => { comp.connect(ctx.destination); });
  out.iphey = await build((ctx, comp) => {
    const an = ctx.createAnalyser();
    comp.connect(an); an.connect(ctx.destination); comp.connect(ctx.destination);
  });
  out.analyserOnly = await build((ctx, comp) => {
    const an = ctx.createAnalyser(); comp.connect(an); an.connect(ctx.destination);
  });
  out.doubleConnect = await build((ctx, comp) => {
    comp.connect(ctx.destination); comp.connect(ctx.destination);
  });
  out.threePaths = await build((ctx, comp) => {
    const an = ctx.createAnalyser(); comp.connect(an); an.connect(ctx.destination);
    const an2 = ctx.createAnalyser(); comp.connect(an2); an2.connect(ctx.destination);
    comp.connect(ctx.destination);
  });
  out.gainPath = await build((ctx, comp) => {
    const g = ctx.createGain(); comp.connect(g); g.connect(ctx.destination);
  });
  out.analyserChain = await build((ctx, comp) => {
    const a = ctx.createAnalyser(), b = ctx.createAnalyser();
    comp.connect(a); a.connect(b); b.connect(ctx.destination);
  });
  return out;
})()
