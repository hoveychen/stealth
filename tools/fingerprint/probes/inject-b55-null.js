// The baseline arm of the b55 padding runs: the instrument with nothing padded.
//
// Every b55 probe installs its overrides and then, five seconds in, reports how
// many times they fired by requesting an image whose query carries the count --
// a station run has no console, because antibot-sweep never sends
// Runtime.enable. This file is that reporting half on its own, so the baseline
// a padded run is compared against was taken with the same
// `addScriptToEvaluateOnNewDocument` registration, the same beacon and the same
// settle as the run being compared. The beacon fires long after the `/tl` POST,
// which goes out at about 800ms, so it cannot be in the body either arm posts.
(() => {
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=null&calls=0'; } catch (e) { /* */ }
    }, 5000);
})();
