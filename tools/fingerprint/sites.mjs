// Third-party detector pages and the in-page extractors that scrape their
// verdicts out of the DOM. Shared by the lightpanda and Chrome collectors so
// both columns of the before/after table are produced the same way.

export const SANNYSOFT_URL = 'https://bot.sannysoft.com/';
export const CREEPJS_URL = 'https://abrahamjuliot.github.io/creepjs/';

// The wider sweep (detector-sweep.mjs). Two of these are dead endpoints that
// answer 37 characters in every browser; they stay on the list so a future run
// notices if they come back rather than silently measuring nine sites and
// reporting twelve. Settle times are what Chrome needs plus headroom.
export const DETECTORS = [
    { name: 'sannysoft', url: SANNYSOFT_URL, settleMs: 6000 },
    { name: 'creepjs', url: CREEPJS_URL, settleMs: 22000 },
    { name: 'areyouheadless', url: 'https://arh.antoinevastel.com/bots/areyouheadless', settleMs: 8000 },
    { name: 'fpscanner', url: 'https://arh.antoinevastel.com/bots/', settleMs: 8000 },
    { name: 'rebrowser', url: 'https://bot-detector.rebrowser.net/', settleMs: 12000 },
    { name: 'deviceinfo', url: 'https://deviceandbrowserinfo.com/are_you_a_bot', settleMs: 12000 },
    { name: 'browserleaks-js', url: 'https://browserleaks.com/javascript', settleMs: 10000 },
    { name: 'browserleaks-tls', url: 'https://tls.browserleaks.com/json', settleMs: 8000 },
    { name: 'amiunique', url: 'https://amiunique.org/fingerprint', settleMs: 15000 },
    { name: 'iphey', url: 'https://iphey.com/', settleMs: 15000 },
    { name: 'pixelscan', url: 'https://pixelscan.net/', settleMs: 18000 },
    { name: 'browserscan', url: 'https://www.browserscan.net/', settleMs: 18000 },
];

// The commercial guards (antibot-sweep.mjs). A different question from the
// twelve above: those pages *report* a fingerprint, these ones *act* on it, and
// the only reading that matters is whether the guard served the site or served a
// challenge. Every entry was recon'd with a bare curl first (Chrome UA, curl's
// own TLS) and `guards` records what came back, so a station that stops guarding
// is visible as a changed field rather than as a silently easy pass —
// nowsecure.nl, for years the community's Cloudflare test site, answers 200 to
// bare curl now and is on the list as a control for exactly that reason.
export const ANTIBOT = [
    // Cloudflare, managed challenge: 403 + `cf-mitigated: challenge` to curl.
    { name: 'cf-scrapingcourse', vendor: 'cloudflare', url: 'https://www.scrapingcourse.com/cloudflare-challenge', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-nopecha', vendor: 'cloudflare', url: 'https://nopecha.com/demo/cloudflare', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-zeroclover', vendor: 'cloudflare', url: 'https://turnstile.zeroclover.io/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-chatgpt', vendor: 'cloudflare', url: 'https://chatgpt.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-claude', vendor: 'cloudflare', url: 'https://claude.ai/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-indeed', vendor: 'cloudflare', url: 'https://www.indeed.com/', settleMs: 25000, guards: 'challenge' },
    // Cloudflare in front, no challenge for a bare curl. These are the controls:
    // a failure here is the engine breaking a CF-fronted ordinary page, which is
    // a different finding from failing a challenge.
    { name: 'cf-nowsecure', vendor: 'cloudflare', url: 'https://nowsecure.nl/', settleMs: 10000, guards: 'none' },
    { name: 'cf-discord', vendor: 'cloudflare', url: 'https://discord.com/', settleMs: 12000, guards: 'none' },
    { name: 'cf-pixiv', vendor: 'cloudflare', url: 'https://www.pixiv.net/', settleMs: 12000, guards: 'none' },
    // DataDome: 403 + `x-datadome: protected` to curl.
    { name: 'dd-datadome', vendor: 'datadome', url: 'https://datadome.co/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-g2', vendor: 'datadome', url: 'https://www.g2.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-leboncoin', vendor: 'datadome', url: 'https://www.leboncoin.fr/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-hermes', vendor: 'datadome', url: 'https://www.hermes.com/', settleMs: 25000, guards: 'challenge' },
    // 403 to curl behind an edge that names no vendor in its *headers* -- but
    // both name themselves on the page they serve a client they do not like, so
    // the vendors are measured rather than unattributed now: sony answers
    // Akamai's "Access Denied ... Reference 0.…" and zillow answers
    // PerimeterX's Press & Hold, with `_pxAppId` and a `#px-captcha` in the DOM.
    // The station names keep their `x-` prefix so readings stay comparable with
    // the snapshots taken before either was known.
    { name: 'x-sony', vendor: 'akamai', url: 'https://www.sony.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'x-zillow', vendor: 'perimeterx', url: 'https://www.zillow.com/', settleMs: 25000, guards: 'challenge' },

    // --- the second batch (2026-08-24) -----------------------------------
    //
    // Fifteen stations turned out to leave exactly one station where headed
    // Chrome passes and this engine does not, which is too coarse a net to
    // steer by: a single station cannot say whether a change helped or whether
    // that station simply moved. These were screened with a bare curl first and
    // only the ones that actually guard the door are here — sixteen other
    // candidates answered 200 to curl and were dropped rather than kept as
    // stations that can only ever say "pass".
    //
    // Every `vendor` below is read off the *measured* response, not assumed:
    // `x-datadome` and `cf-mitigated` name themselves in a header, Akamai and
    // Kasada by `server:`/`x-kpsdk-*`, and PerimeterX by its cookie. Where the
    // headers name nobody the prefix stays `x-`, the way sony and zillow did
    // until their pages were read.
    { name: 'cf-ubereats', vendor: 'cloudflare', url: 'https://www.ubereats.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-doordash', vendor: 'cloudflare', url: 'https://www.doordash.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-glassdoor', vendor: 'cloudflare', url: 'https://www.glassdoor.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-etsy', vendor: 'datadome', url: 'https://www.etsy.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-seloger', vendor: 'datadome', url: 'https://www.seloger.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-saks', vendor: 'datadome', url: 'https://www.saksfifthavenue.com/', settleMs: 25000, guards: 'challenge' },
    // DataDome behind Cloudflare: the 403 is CF's edge, the cookie is DataDome's.
    { name: 'dd-allopneus', vendor: 'datadome', url: 'https://www.allopneus.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'ak-homedepot', vendor: 'akamai', url: 'https://www.homedepot.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'ak-macys', vendor: 'akamai', url: 'https://www.macys.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'ak-kohls', vendor: 'akamai', url: 'https://www.kohls.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'ak-expedia', vendor: 'akamai', url: 'https://www.expedia.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'px-wayfair', vendor: 'perimeterx', url: 'https://www.wayfair.com/', settleMs: 25000, guards: 'challenge' },
    // Kasada, which no station covered before this one.
    { name: 'ks-canadagoose', vendor: 'kasada', url: 'https://www.canadagoose.com/', settleMs: 25000, guards: 'challenge' },
    // Kasada too, which its headers say outright: a bare curl to it comes back
    // 429 with `x-kpsdk-*` set. The `x-` prefix stays in the name so readings
    // keep comparing with the ones taken while the vendor was still unknown.
    { name: 'x-hyatt', vendor: 'kasada', url: 'https://www.hyatt.com/', settleMs: 25000, guards: 'challenge' },

    // --- the third batch (2026-09-13) ------------------------------------
    //
    // Screened the same way as the second: a browser-shaped bare curl (Chrome
    // 152 user-agent, the client hints and Sec-Fetch-* headers that go with
    // it), and a candidate that answered 200 was dropped rather than kept as a
    // station that can only ever say "pass". Seventy candidates went in and
    // these came out; the `vendor` on each is what the response named itself,
    // never an assumption.
    //
    // The 200s are worth stating because they are the reason this batch leans
    // the way it does. Ten Akamai-fronted sites (walmart, bestbuy, lowes,
    // costco, sephora, united, delta, walgreens, nike, rei) all answered a
    // bare curl with 200 and an `_abck`/`bm_sz` cookie: that family mostly
    // guards with its JS sensor rather than at the door, so it screens out
    // here even though it is a guard in a browser. Same for both PerimeterX
    // candidates (target, fiverr: `_pxhd`, 200) and both Imperva ones
    // (pepsico, imperva.com: `x-iinfo`, 200) -- which is why Kasada still has
    // one station and Imperva none. Finding a station for those two needs a
    // screen that runs JavaScript, not a better candidate list.
    //
    // `guards: 'block'` is new here. The eight `'challenge'` Cloudflare rows
    // answer 403 *with* `cf-mitigated: challenge`, so an interstitial is
    // coming; medium and gamestop answer a 403 with no such header, which is
    // the WAF refusing outright. Both shapes are worth having and they are not
    // the same reading, so they are not spelled the same. Nothing in the sweep
    // branches on this field -- it is recorded so a station that changes
    // behaviour shows up as a changed field.
    { name: 'cf-upwork', vendor: 'cloudflare', url: 'https://www.upwork.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-crunchyroll', vendor: 'cloudflare', url: 'https://www.crunchyroll.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-udemy', vendor: 'cloudflare', url: 'https://www.udemy.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-namecheap', vendor: 'cloudflare', url: 'https://www.namecheap.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-coinbase', vendor: 'cloudflare', url: 'https://www.coinbase.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-mercari', vendor: 'cloudflare', url: 'https://www.mercari.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-bunnings', vendor: 'cloudflare', url: 'https://www.bunnings.com.au/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-chemistwarehouse', vendor: 'cloudflare', url: 'https://www.chemistwarehouse.com.au/', settleMs: 25000, guards: 'challenge' },
    { name: 'cf-medium', vendor: 'cloudflare', url: 'https://www.medium.com/', settleMs: 25000, guards: 'block' },
    { name: 'cf-gamestop', vendor: 'cloudflare', url: 'https://www.gamestop.com/', settleMs: 25000, guards: 'block' },
    { name: 'dd-blablacar', vendor: 'datadome', url: 'https://www.blablacar.fr/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-leroymerlin', vendor: 'datadome', url: 'https://www.leroymerlin.fr/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-tripadvisor', vendor: 'datadome', url: 'https://www.tripadvisor.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-grainger', vendor: 'datadome', url: 'https://www.grainger.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-neimanmarcus', vendor: 'datadome', url: 'https://www.neimanmarcus.com/', settleMs: 25000, guards: 'challenge' },
    // DataDome behind someone else's edge, the way dd-allopneus sits behind
    // Cloudflare's: sncf-connect answers 403 with both `cf-mitigated` absent
    // and `x-datadome` present, zoro with Akamai's `ak_bmsc` beside the
    // DataDome cookie. The 403 is the edge; the cookie names who judged.
    { name: 'dd-sncf', vendor: 'datadome', url: 'https://www.sncf-connect.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'dd-zoro', vendor: 'datadome', url: 'https://www.zoro.com/', settleMs: 25000, guards: 'challenge' },
    // The one Akamai candidate that refuses at the door rather than behind its
    // sensor -- `server: AkamaiGHost` on a 403, the same shape ak-kohls has.
    { name: 'ak-bloomingdales', vendor: 'akamai', url: 'https://www.bloomingdales.com/', settleMs: 25000, guards: 'challenge' },
    // Its headers name nobody, the way sony's and zillow's did until their
    // pages were read -- and this one's page has now been read too: it answers
    // PerimeterX's "Access to this page has been denied" in 21 nodes. Measured
    // over seven runs it refuses us about three times in ten and serves the
    // site otherwise, so it is a rate rather than a door; the `x-` prefix stays
    // so readings keep comparing with the ones taken before the vendor showed.
    { name: 'x-sweetwater', vendor: 'perimeterx', url: 'https://www.sweetwater.com/', settleMs: 25000, guards: 'challenge' },

    // --- the fourth batch (2026-09-17): two vendors no station covered ----
    //
    // Found by narrowing the tell to what a site cannot claim speculatively:
    // response headers other than the CSP, and hosts the markup actually
    // references (`scratch/s35/vendor-probe.py`). The probe before it matched
    // the whole curl response, which meant it also matched the
    // `content-security-policy` allowlist — and a CSP enumerates every third
    // party a site *may* ever load, so petco.com read as hCaptcha + DataDome +
    // Cloudflare at once. Nobody runs three. About a hundred consumer sites
    // were screened this way and only these two families came back real:
    // hCaptcha, Arkose, F5 Shape, FingerprintJS, Radware and Netacea scored
    // zero, their earlier "hits" having all been CSP entries.
    //
    // Imperva (Incapsula), whose interstitial answers *200*: boots serves
    // "Pardon Our Interruption" with a normal status line, so the status rule
    // never sees it — the same trap PerimeterX's Press & Hold sets. hertz is
    // the control: the same vendor, 175KB of its real site. (thrifty.com and
    // dollar.com are the same deployment as hertz and add nothing.)
    { name: 'im-boots', vendor: 'imperva', url: 'https://www.boots.com/', settleMs: 25000, guards: 'challenge' },
    { name: 'im-hertz', vendor: 'imperva', url: 'https://www.hertz.com/rentacar/reservation/', settleMs: 25000, guards: 'none' },
    // AWS WAF. binance answers 202 and a two-kilobyte page that is nothing but
    // the integration: an encrypted `gokuProps` blob and the token SDK.
    // hollandandbarrett is its control — real site, SDK loaded, no challenge —
    // which is also why the SDK script is not on its own a challenge mark.
    { name: 'aw-binance', vendor: 'awswaf', url: 'https://www.binance.com/en', settleMs: 25000, guards: 'challenge' },
    { name: 'aw-hollandandbarrett', vendor: 'awswaf', url: 'https://www.hollandandbarrett.com/', settleMs: 25000, guards: 'none' },
];

// What a guard's own page looks like from inside it. Signals are recorded raw
// and the verdict is derived outside the page, so a reading can be re-judged
// later without re-running the sweep.
//
// The Cloudflare marks are the interstitial's, not the CDN's: `_cf_chl_opt` is
// the challenge script's config object, `/cdn-cgi/challenge-platform/` its
// loader, and `#challenge-form` / `#challenge-running` its DOM. A Turnstile
// *widget* (`challenges.cloudflare.com/turnstile`) is deliberately a separate
// field — a site can embed one on a page it served us perfectly happily, which
// is not the same as being stopped at the door.
export const extractAntibot = `(() => {
  const html = document.documentElement ? document.documentElement.outerHTML : '';
  const text = (document.body && document.body.innerText) || '';
  const srcs = Array.from(document.querySelectorAll('script[src], iframe[src]'))
    .map((e) => e.getAttribute('src') || '');
  const has = (sel) => !!document.querySelector(sel);
  return {
    title: document.title,
    href: location.href,
    ready: document.readyState,
    nodes: document.getElementsByTagName('*').length,
    textLength: text.length,
    text: text.slice(0, 1200),
    cf: {
      chlOpt: typeof window._cf_chl_opt !== 'undefined',
      platformScript: srcs.some((s) => s.includes('/cdn-cgi/challenge-platform/')),
      challengeDom: has('#challenge-form') || has('#challenge-running') || has('#cf-chl-widget') || has('#challenge-stage'),
      justAMoment: /just a moment|un momento|checking your browser|\\u60a8\\u7684\\u8bf7\\u6c42/i.test(document.title + ' ' + text.slice(0, 400)),
      blocked: /sorry, you have been blocked|error 1020|cloudflare ray id/i.test(text),
      turnstileWidget: srcs.some((s) => s.includes('challenges.cloudflare.com/turnstile')),
      rayId: (html.match(/[Rr]ay ID:?\\s*<?[a-z]*>?\\s*([0-9a-f]{16})/) || [])[1] || null,
    },
    dd: {
      captchaDelivery: srcs.some((s) => s.includes('captcha-delivery.com')) || /captcha-delivery\\.com/.test(html),
      blockText: /vous avez \\u00e9t\\u00e9 bloqu|you have been blocked|blocked by datadome|enable javascript and cookies to continue/i.test(text),
    },
    // PerimeterX. Its interstitial is the "Press & Hold" human challenge, which
    // answers 200 once the widget has loaded and so is invisible to the status
    // rule -- a headless Chrome at zillow scored a clean pass on it before this
    // mark existed. The reference id is what separates the challenge page from
    // an ordinary page that happens to use the words.
    px: {
      pressAndHold: /press (?:&|and) hold to confirm you are a human/i.test(text),
      deniedTitle: /access to this page has been denied/i.test(document.title),
      refId: /reference id:?\\s*[0-9a-f-]{8,}/i.test(text),
      captchaDom: has('#px-captcha') || has('[id^="px-captcha"]'),
      appId: typeof window._pxAppId !== 'undefined' || typeof window._pxAction !== 'undefined',
    },
    // Akamai's own denial page, which names no vendor and carries a dotted
    // reference. Recorded rather than judged: it arrives as a bare 4xx, which
    // the status rule already refuses, and the mark is here so a 200-cloaked one
    // does not read as a pass.
    akamai: {
      accessDenied: /^access denied$/i.test(document.title.trim()) ||
        /you don't have permission to access this page/i.test(text),
      reference: /reference #?\\s*[0-9a-f.]{10,}/i.test(text),
    },
    // Kasada. Recorded, not judged -- see the note in antibot-sweep's
    // \`verdict\`: these marks stay set on a page Kasada *served*, so a rule on
    // them scores a pass as a challenge. What they are good for is attribution:
    // knowing which guard is behind a reading. Measured off canadagoose's own
    // refusal -- the bootstrap assigns \`window.KPSDK\` before anything else
    // runs, and the script it pulls sits under a pair of uuid path segments
    // (\`/<uuid>/<uuid>/ips.js\`), which is what separates it from an ordinary
    // asset path. An unsolved interstitial is 681 bytes with no text at all,
    // which \`empty\` and the status rule catch without help.
    kasada: {
      sdk: typeof window.KPSDK !== 'undefined',
      script: srcs.some((s) => /\\/[0-9a-f]{8}-[0-9a-f-]{27}\\/[0-9a-f]{8}-[0-9a-f-]{27}\\//.test(s)),
    },
    // Imperva (Incapsula), whose interstitial answers 200 -- so unlike
    // Akamai's denial there is no status line to fall back on, and unlike
    // Kasada's marks these have to separate the interstitial from a page
    // Imperva served. Two of the four ride along on served pages and are
    // recorded rather than judged: \`protection\` is the reese84 bootstrap,
    // which stays loaded the way KPSDK does, and \`resource\` turned out to be
    // one too -- hertz hands over 175KB of its real storefront with
    // \`/_Incapsula_Resource\` in it, and judging on that mark scored four
    // consecutive real pages, on both arms, as challenges. What is left is the
    // interstitial template's own wording and the incident id on the refusal.
    // Note the title lives inside a <noscript> on the interstitial, so
    // \`document.title\` is empty there and the wording has to be matched
    // against the markup rather than the title.
    imperva: {
      interruption: /pardon our interruption/i.test(html),
      resource: /_Incapsula_Resource/.test(html),
      incidentId: /incapsula incident id/i.test(text),
      protection: typeof window.reeseSkipExpirationCheck !== 'undefined' ||
        typeof window.initializeProtection !== 'undefined' ||
        typeof window.isImpervaSpaSupport !== 'undefined',
    },
    // AWS WAF. Its challenge is a 202 carrying nothing but the integration:
    // \`gokuProps\` is the server-injected encrypted blob, which is what makes
    // it the interstitial's own mark. The token SDK under \`*.awswaf.com\` is
    // deliberately separate -- hollandandbarrett loads it on the real site it
    // serves us, so a rule on the script would score that pass as a challenge,
    // which is the trap the Kasada note below describes.
    awswaf: {
      gokuProps: typeof window.gokuProps !== 'undefined',
      cookieDomainList: typeof window.awsWafCookieDomainList !== 'undefined',
      // Not \`challengeDom\`: antibot-sweep flattens every one of these groups
      // into a single \`marks\` object, so a name reused across two vendors
      // silently overwrites the earlier one -- Cloudflare already has a
      // \`challengeDom\` and it comes first.
      wafChallengeDom: has('#challenge-container') || has('#captcha-container'),
      integration: typeof window.AwsWafIntegration !== 'undefined',
      sdkScript: srcs.some((s) => /\\.awswaf\\.com\\//.test(s)),
    },
    // Any guard's last resort: an empty document with nothing on it.
    empty: text.trim().length === 0,
  };
})()`;

// Words a detector uses to say what it decided. Counted, not interpreted: the
// question this sweep answers is "did the page finish and reach a verdict",
// not "what score did we get" — per-site scrapers rot, and a page that never
// returns a fingerprint is a louder signal than a slightly wrong one.
export const VERDICT_WORDS =
    /\b(bot|headless|automation|automated|webdriver|puppeteer|selenium|human|trustworthy|suspicious|detected|not a robot|robot)\b/gi;

// Coarse, engine-agnostic "how far did this page get" reading.
export const extractReach = `(() => {
  const text = (document.body && document.body.innerText) || '';
  return {
    title: document.title,
    href: location.href,
    ready: document.readyState,
    nodes: document.getElementsByTagName('*').length,
    textLength: text.length,
    text: text.slice(0, 4000),
    // Recorded per site, not once per run: a responsive layout deals a
    // different number of cards at a different width, so a node count is only
    // comparable against another count taken at the same width. A baseline
    // that does not carry its own viewport is how G7's pixelscan "+184
    // elements" turned out to be a window that happened to be 1200 wide.
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    dpr: window.devicePixelRatio,
  };
})()`;

// bot.sannysoft.com renders every check as a <tr> of <th>name</th><td>value</td>
// where the <td> carries a passed/failed/warn class.
export const extractSannysoft = `(() => {
  const rows = [];
  for (const tr of document.querySelectorAll('tr')) {
    const cells = tr.querySelectorAll('th, td');
    if (cells.length < 2) continue;
    const name = (cells[0].textContent || '').trim();
    const cell = cells[1];
    if (!name) continue;
    rows.push({
      name,
      value: (cell.textContent || '').trim().slice(0, 200),
      status: cell.className || cell.getAttribute('class') || '',
      id: cell.id || '',
    });
  }
  return { title: document.title, rowCount: rows.length, rows };
})()`;

// CreepJS is heavy and async. Its DOM is a flat list of "label:" lines followed
// by their values, so line-oriented regexes grab the wrong line; instead we key
// off the label and read the *next* non-empty line, and always keep the full
// text so P7 can diff before/after by hand.
export const extractCreepJs = `(() => {
  const text = (document.body && document.body.innerText) || '';
  const lines = text.split('\\n').map((l) => l.trim());
  // Value that follows a given label line (CreepJS renders "label:" then value).
  const after = (label) => {
    const i = lines.findIndex((l) => l.toLowerCase() === label.toLowerCase());
    if (i === -1) return null;
    for (let j = i + 1; j < lines.length && j < i + 3; j++) if (lines[j]) return lines[j].slice(0, 200);
    return null;
  };
  const inline = (re) => { const m = text.match(re); return m ? m[1].trim() : null; };
  const fpId = inline(/FP ID:\\s*([^\\n]+)/i);
  return {
    title: document.title,
    // "Computing..." means CreepJS never finished on this engine.
    computed: !!fpId && !/computing/i.test(fpId),
    fpId,
    fuzzy: inline(/Fuzzy:\\s*([0-9a-f]+)/i),
    likeHeadless: inline(/([0-9]+%)\\s*like headless/i),
    headlessPct: inline(/([0-9]+%)\\s*headless/i),
    stealthPct: inline(/([0-9]+%)\\s*stealth/i),
    chromium: after('chromium:'),
    platformHints: after('platform hints:'),
    lies: inline(/lies\\s*\\(([0-9]+)\\)/i),
    textLength: text.length,
    text: text.slice(0, 20000),
  };
})()`;
