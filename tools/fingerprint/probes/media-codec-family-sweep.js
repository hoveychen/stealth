// What Chrome answers for parametrised codec strings, and for the mpegurl
// container spellings, so the media table can carry the rule rather than the
// handful of literals the generator happened to ask about.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/media-codec-family-sweep.js --headed-ua
(() => {
    const out = {};
    const v = document.createElement('video');
    const ask = (t) => [v.canPlayType(t), MediaSource.isTypeSupported(t), MediaRecorder.isTypeSupported(t)].join('|');

    // Container spellings around the mpegurl / mpeg family.
    for (const c of [
        'audio/x-mpegurl', 'audio/mpegurl', 'application/x-mpegurl',
        'application/vnd.apple.mpegurl', 'audio/x-mpeg', 'video/x-mpeg',
        'audio/mpeg', 'video/mpeg', 'audio/wave', 'audio/x-mpegURL',
    ]) out['bare ' + c] = ask(c);

    // avc1: profile/constraint/level as six hex digits. Which of the three
    // fields does Chrome actually check?
    for (const k of [
        'avc1.42E01E', 'avc1.42c00d', 'avc1.42C00D', 'avc1.64003E', 'avc1.640033',
        'avc1.4d001f', 'avc1.58A01E', 'avc1.6E001E', 'avc1.7A001E', 'avc1.F4001E',
        'avc1.2C001E', 'avc1.00001E', 'avc1.FF001E', 'avc1.42E0FF', 'avc1.42E000',
        'avc1.42E01', 'avc1.42E01EE', 'avc1.42E01G', 'avc1', 'avc1.', 'avc1.42',
        'avc3.64003E', 'avc3.42c00d', 'avc3.F4001E', 'avc3',
    ]) out['mp4 ' + k] = ask('video/mp4;codecs=' + k);

    // hevc: hvc1/hev1.<profile-space><profile>.<compat>.<tier><level>.<constraints>
    for (const k of [
        'hvc1.1.6.L93.B0', 'hvc1.1.6.L186.B0', 'hev1.1.6.L186.B0', 'hev1.1.6.L93.B0',
        'hvc1.2.4.L120.B0', 'hvc1.1.6.H186.B0', 'hvc1.1.6.L255.B0', 'hvc1.1.6.L186',
        'hvc1.1.6', 'hvc1.1', 'hvc1', 'hvc1.9.6.L186.B0', 'hvc1.1.6.L186.B0.0.0.0.0',
    ]) out['mp4 ' + k] = ask('video/mp4;codecs=' + k);

    // av1: av01.<profile>.<level><tier>.<depth>
    for (const k of [
        'av01.0.05M.08', 'av01.0.19M.08', 'av01.0.19M.10', 'av01.0.19H.08',
        'av01.1.19M.08', 'av01.2.19M.10', 'av01.0.31M.08', 'av01.0.00M.08',
        'av01.3.19M.08', 'av01.0.19M.12', 'av01.0.19M.09', 'av01',
    ]) out['mp4 ' + k] = ask('video/mp4;codecs=' + k);

    // vp9 both spellings.
    for (const k of [
        'vp09.00.10.08', 'vp09.00.51.08', 'vp09.02.10.10', 'vp09.03.10.10',
        'vp09.01.10.08', 'vp9', 'vp8', 'vp09',
    ]) out['mp4 ' + k] = ask('video/mp4;codecs=' + k);

    // Audio codecs inside mp4, which is what the recorder rows pair with video.
    for (const k of ['mp4a.40.2', 'mp4a.40.5', 'mp4a.40.29', 'mp4a.69', 'opus', 'flac', 'mp3', 'ac-3', 'ec-3']) {
        out['mp4 ' + k] = ask('video/mp4;codecs=' + k);
    }

    // The exact pairs the read log caught.
    for (const t of [
        'video/mp4;codecs=avc1.64003E,mp4a.40.2', 'video/mp4;codecs=avc1.64003E,opus',
        'video/mp4;codecs=avc3.64003E,mp4a.40.2', 'video/mp4;codecs=avc3.64003E,opus',
        'video/mp4;codecs=hvc1.1.6.L186.B0,mp4a.40.2', 'video/mp4;codecs=hvc1.1.6.L186.B0,opus',
        'video/mp4;codecs=hev1.1.6.L186.B0,mp4a.40.2', 'video/mp4;codecs=hev1.1.6.L186.B0,opus',
        'video/mp4;codecs=av01.0.19M.08,mp4a.40.2', 'video/mp4;codecs=av01.0.19M.08,opus',
        'video/mp4; codecs="avc1.42c00d"', 'audio/x-mpegurl',
    ]) out['pair ' + t] = ask(t);

    // Same families in the other recording containers, so the rule is not fitted
    // to mp4 alone.
    for (const c of ['video/webm', 'video/x-matroska', 'audio/mp4', 'audio/webm']) {
        for (const k of ['avc1.64003E', 'hvc1.1.6.L186.B0', 'av01.0.19M.08', 'vp09.00.51.08', 'mp4a.40.2', 'opus']) {
            out['other ' + c + ' ' + k] = ask(c + ';codecs=' + k);
        }
    }

    return out;
})()
