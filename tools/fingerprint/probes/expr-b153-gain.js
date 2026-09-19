(async () => {
  const build = async (wire) => {
    const ctx = new OfflineAudioContext(1, 5000, 44100);
    const osc = ctx.createOscillator();
    osc.type = 'triangle'; osc.frequency.value = 10000;
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
  return {
    gainDefault: await build((ctx, c) => { const g = ctx.createGain(); c.connect(g); g.connect(ctx.destination); }),
    gainOne: await build((ctx, c) => { const g = ctx.createGain(); g.gain.value = 1; c.connect(g); g.connect(ctx.destination); }),
    gainHalf: await build((ctx, c) => { const g = ctx.createGain(); g.gain.value = 0.5; c.connect(g); g.connect(ctx.destination); }),
    gainPlusDirect: await build((ctx, c) => { const g = ctx.createGain(); c.connect(g); g.connect(ctx.destination); c.connect(ctx.destination); }),
  };
})()
