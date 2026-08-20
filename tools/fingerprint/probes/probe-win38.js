(async () => {
  // Batch 16 follow-up: probe-win37 sorted every feature set before recording
  // it, so the real enumeration order was lost. This one keeps insertion order
  // and adds the reachable adapter/device identity + GPUDeviceLostInfo values.
  const out = {};
  out.wgslOrder = [...navigator.gpu.wgslLanguageFeatures];

  const a = await navigator.gpu.requestAdapter();
  if (!a) return { ...out, adapter: 'null' };

  out.adapterFeaturesOrder = [...a.features];
  out.adapterFeaturesSameEachRead = a.features === a.features;
  out.adapterLimitsSameEachRead = a.limits === a.limits;
  out.adapterInfoSameEachRead = a.info === a.info;
  out.adapterOwn = Object.getOwnPropertyNames(a).join(',');
  out.adapterHasIsFallbackAdapter = 'isFallbackAdapter' in a;
  out.requestDeviceArity = a.requestDevice.length;

  const d = await a.requestDevice();
  out.deviceFeaturesOrder = [...d.features];
  out.deviceLabelInitial = d.label;
  d.label = 'hello';
  out.deviceLabelAfterSet = d.label;
  d.label = '';
  out.deviceQueueSameEachRead = d.queue === d.queue;
  out.deviceLostSameEachRead = d.lost === d.lost;
  out.deviceAdapterInfoSameAsAdapterInfo = d.adapterInfo === a.info;
  out.deviceAdapterInfoVendor = d.adapterInfo.vendor;
  out.queueLabelInitial = d.queue.label;
  d.queue.label = 'q';
  out.queueLabelAfterSet = d.queue.label;
  out.deviceOnUncapturedError = d.onuncapturederror;

  const race = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(() => r('pending'), ms))]);
  out.lostBeforeDestroy = await race(d.lost.then((v) => ({ reason: v.reason, message: v.message })), 400);
  d.destroy();
  out.lostAfterDestroy = await race(
    d.lost.then((v) => ({
      reason: v.reason,
      message: v.message,
      brand: Object.prototype.toString.call(v),
    })),
    1500,
  );

  // A second adapter/device pair: are the objects fresh or cached?
  const a2 = await navigator.gpu.requestAdapter();
  out.adapterCachedAcrossCalls = a2 === a;
  return out;
})()
