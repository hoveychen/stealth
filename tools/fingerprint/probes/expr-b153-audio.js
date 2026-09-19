(async () => {
  const out = { AudioContext: typeof AudioContext, OfflineAudioContext: typeof OfflineAudioContext };
  try {
    const ctx = new OfflineAudioContext(1, 44100, 44100);
    const osc = ctx.createOscillator();
    osc.type = 'triangle';
    osc.frequency.value = 10000;
    const comp = ctx.createDynamicsCompressor();
    osc.connect(comp); comp.connect(ctx.destination);
    osc.start(0);
    const buf = await ctx.startRendering();
    const ch = buf.getChannelData(0);
    let sum = 0;
    for (let i = 4500; i < 5000; i++) sum += Math.abs(ch[i]);
    out.sum = sum;
    out.sample = [ch[4500], ch[4700], ch[4900]];
    out.length = buf.length;
    out.sampleRate = buf.sampleRate;
  } catch (e) { out.error = String(e); }
  return out;
})()
