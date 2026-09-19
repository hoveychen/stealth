(async () => {
  const run = async (tweak) => {
    const ctx = new OfflineAudioContext(1, 5000, 44100);
    const osc = ctx.createOscillator();
    osc.type = 'triangle';
    osc.frequency.value = 10000;
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -50;
    comp.knee.value = 40;
    comp.ratio.value = 12;
    comp.attack.value = 0;
    comp.release.value = 0.25;
    if (tweak) tweak(ctx, osc, comp);
    osc.connect(comp); comp.connect(ctx.destination);
    osc.start(0);
    const buf = await ctx.startRendering();
    const ch = buf.getChannelData(0);
    let sum = 0;
    for (let i = ch.length - 500; i < ch.length; i++) sum += Math.abs(ch[i]);
    return sum;
  };
  return {
    plain: await run(null),
    setValueAtTime: await run((ctx, osc, comp) => {
      comp.attack.setValueAtTime(0, ctx.currentTime);
    }),
    destChannelCount: (new OfflineAudioContext(1, 5000, 44100)).destination.channelCount,
  };
})()
