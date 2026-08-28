// The members the cf-scrapingcourse challenge asked this engine for and did not
// get, taken off the Debug context's unknown_properties log and filtered down to
// the ones a real Chrome answers. Everything else in that log is a sentinel
// (_phantom, angular, pyimport) or the challenge's own globals, where being
// absent is the right answer.
(() => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'ERR:' + e.name; } };
    t('window.CSS', () => typeof CSS);
    t('window.console', () => typeof console);
    t('window.chrome', () => typeof window.chrome);
    t('chrome own keys', () => (window.chrome ? Object.keys(window.chrome) : null));
    t('window.SharedArrayBuffer', () => typeof SharedArrayBuffer);
    t('window.Summarizer', () => typeof globalThis.Summarizer);
    t('ontouchstart in window', () => 'ontouchstart' in window);
    t('document.lang', () => typeof document.lang);
    t('TextMetrics.emHeightAscent', () => {
        const m = document.createElement('canvas').getContext('2d').measureText('x');
        return { emHeightAscent: m.emHeightAscent, emHeightDescent: m.emHeightDescent,
            has: 'emHeightAscent' in m, proto: 'emHeightAscent' in TextMetrics.prototype };
    });
    t('NetworkInformation', () => {
        const c = navigator.connection;
        return { type: c && c.type, downlinkMax: c && c.downlinkMax,
            protoKeys: Object.getOwnPropertyNames(Object.getPrototypeOf(c)) };
    });
    t('KHR_parallel_shader_compile', () => {
        const gl = document.createElement('canvas').getContext('webgl');
        const e = gl && gl.getExtension('KHR_parallel_shader_compile');
        return e ? { has: 'MAX_SHADER_COMPILER_THREADS_KHR' in e, v: e.MAX_SHADER_COMPILER_THREADS_KHR,
            keys: Object.keys(e), protoKeys: Object.getOwnPropertyNames(Object.getPrototypeOf(e)) } : String(e);
    });
    t('GPUSupportedLimits keys', () => (typeof GPUSupportedLimits === 'function'
        ? Object.getOwnPropertyNames(GPUSupportedLimits.prototype).length : 'absent'));
    t('GPUSupportedLimits subgroup', () => (typeof GPUSupportedLimits === 'function'
        ? ['minSubgroupSize', 'maxSubgroupSize'].map((k) => k + '=' + (k in GPUSupportedLimits.prototype)) : 'absent'));
    t('GPUAdapter.isFallbackAdapter', () => (typeof GPUAdapter === 'function'
        ? 'isFallbackAdapter' in GPUAdapter.prototype : 'absent'));
    t('GPUAdapter proto keys', () => (typeof GPUAdapter === 'function'
        ? Object.getOwnPropertyNames(GPUAdapter.prototype) : 'absent'));
    return out;
})();
