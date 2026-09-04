// Minimal zero-dependency CDP client (Node >= 22 global WebSocket).
// Used by the fingerprint collectors so the baseline does not depend on a
// puppeteer/playwright version matching lightpanda's partial CDP surface.

export class Cdp {
    constructor(url) {
        this.url = url;
        this.nextId = 1;
        this.pending = new Map();
        this.listeners = [];
    }

    static async connect(httpBase) {
        const res = await fetch(`${httpBase}/json/version`);
        const { webSocketDebuggerUrl } = await res.json();
        const cdp = new Cdp(webSocketDebuggerUrl);
        await cdp.open();
        return cdp;
    }

    open() {
        return new Promise((resolve, reject) => {
            this.ws = new WebSocket(this.url);
            this.ws.addEventListener('open', () => resolve());
            this.ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message ?? e.type}`)));
            this.ws.addEventListener('message', (ev) => this.onMessage(ev.data));
        });
    }

    onMessage(raw) {
        let msg;
        try {
            msg = JSON.parse(raw);
        } catch {
            return;
        }
        if (msg.id !== undefined && this.pending.has(msg.id)) {
            const { resolve, reject } = this.pending.get(msg.id);
            this.pending.delete(msg.id);
            if (msg.error) reject(new Error(`${msg.error.code} ${msg.error.message}`));
            else resolve(msg.result);
            return;
        }
        for (const fn of this.listeners) fn(msg);
    }

    on(fn) {
        this.listeners.push(fn);
    }

    send(method, params, sessionId) {
        const id = this.nextId++;
        const payload = { id, method };
        if (params) payload.params = params;
        if (sessionId) payload.sessionId = sessionId;
        this.ws.send(JSON.stringify(payload));
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            setTimeout(() => {
                if (this.pending.delete(id)) reject(new Error(`timeout: ${method}`));
            }, 30000);
        });
    }

    close() {
        try {
            this.ws.close();
        } catch {
            /* already gone */
        }
    }
}

// Open a page target and attach, returning its sessionId.
export async function newPage(cdp) {
    const { browserContextId } = await cdp.send('Target.createBrowserContext');
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    return { sessionId, targetId, browserContextId };
}

// Navigate and give the page a chance to run its scripts. lightpanda has no
// reliable networkIdle signal across all versions, so we poll readyState.
export async function goto(cdp, sessionId, url, { settleMs = 3000 } = {}) {
    await cdp.send('Page.navigate', { url }, sessionId);
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
        try {
            const r = await evaluate(cdp, sessionId, 'document.readyState');
            if (r === 'complete') break;
        } catch {
            /* context not ready yet */
        }
        await sleep(200);
    }
    await sleep(settleMs);
}

export async function evaluate(cdp, sessionId, expression, { awaitPromise = false } = {}) {
    const res = await cdp.send(
        'Runtime.evaluate',
        { expression, returnByValue: true, awaitPromise },
        sessionId,
    );
    if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page exception: ${d.text} ${d.exception?.description ?? ''}`);
    }
    return res.result?.value;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The device scale factor this engine reports to every page, unconditionally.
// A Chrome reference arm launched without `--force-device-scale-factor` answers
// 1, so every two-arm reading with devicePixelRatio anywhere in it comes out
// systematically different -- and reads as a defect in this engine.
//
// That is not hypothetical: on cf-scrapingcourse the largest surface the guard
// reads, `JSON.stringify(getComputedStyle(el))`, showed 8 of 736 values
// disagreeing (the three rule widths, 1.5px here against 3px there) against a
// dpr-1 arm. At matched scale the whole 30918-byte span is byte-identical. The
// engine was right the entire time -- 1.5px is three device pixels, which
// `src/browser/tests/css/rule_width_keywords.html` already records.
//
// `Emulation.setDeviceMetricsOverride` cannot substitute for the switch, and
// passing `deviceScaleFactor: 1` there actively creates the mismatch: this
// engine ignores that parameter outright (`src/cdp/domains/emulation.zig` warns
// for anything but 0/1 and applies none of them) while Chrome honours it, so
// the value only ever moves the reference arm -- to the wrong scale.
export const PERSONA_DEVICE_SCALE_FACTOR = 2;

// Launch flags pinning a Chrome reference arm to the persona's scale, unless
// the caller already asked for a scale of its own -- the same guard
// `dump-fonts.mjs` grew for the same reason. Returns [] for a caller that did.
export function personaScaleFlags(chromeArgs = []) {
    return chromeArgs.some((a) => String(a).startsWith('--force-device-scale-factor'))
        ? []
        : [`--force-device-scale-factor=${PERSONA_DEVICE_SCALE_FACTOR}`];
}

// The other axis a launch flag cannot carry, and the one that drifts on its
// own: this engine hardcodes `prefers-color-scheme: light`
// (css/MediaQuery.zig), while a headless Chrome inherits the HOST's appearance
// -- which on a Mac set to Auto changes with the time of day. Two runs of the
// same command nine hours apart were measured answering `dark` and then
// `light`, so this is not a constant to look up once and trust.
//
// It is not a value that comes out slightly different either. Turnstile puts
// the theme in the program's URL
// (`.../<sitekey>/dark/fbE/new/normal` against `.../light/...`), verified in
// both directions here: emulating `dark` moves the URL to `dark` and emulating
// `light` moves it back. So the arms are handed DIFFERENT BUILDS of the widget,
// and every byte of its stylesheet -- and every pixel it draws of itself -- is
// then a different question rather than a different answer.
//
// Nine bytes of that stylesheet were read as a serialisation defect in this
// engine before the theme was noticed. The engine was right
// (tests/css/declaration_serialize.html#a_zero_in_a_transform_function_keeps_its_unit).
export const PERSONA_PREFERS_COLOR_SCHEME = 'light';

// Pin the media features on a Chrome arm. This engine's
// Emulation.setEmulatedMedia is a noop, and it already answers the persona's
// values, so sending this to both arms is harmless and keeps call sites from
// having to branch. Failures are swallowed for the same reason.
export async function pinPersonaMedia(cdp, sessionId) {
    await cdp.send('Emulation.setEmulatedMedia', {
        features: [{ name: 'prefers-color-scheme', value: PERSONA_PREFERS_COLOR_SCHEME }],
    }, sessionId).catch(() => { /* noop on this engine */ });
}

// What the page actually answers for each axis the persona claims. Read back
// rather than assumed: passing a flag is not the same as the arm being on it,
// and a stale browser reusing the port will answer for the flags IT was given.
export const PERSONA_AXES_EXPR = `({
  devicePixelRatio: window.devicePixelRatio,
  prefersColorScheme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
  innerWidth: window.innerWidth,
  innerHeight: window.innerHeight,
  screenWidth: screen.width,
  screenHeight: screen.height,
})`;

// Throws unless the arm is on the persona's scale and theme.
//
// ⚠️ Call this on the SETUP page, before navigating to a station. It is a
// `Runtime.evaluate` against the page, and on a live challenge an extra
// execution -- or any text it leaves in the realm -- is itself a variable
// (see the payload-size readings in tools/fingerprint/README.md).
//
// `innerWidth`/`screen` are reported but NOT asserted: the display persona is a
// separate axis this does not claim to have aligned (a dpr-2 Chrome answers
// screen 400x300 against this engine's 1920x1200), and failing on it would stop
// every harness. They are printed so a reading that turns on them is not
// mistaken for one that does not.
export async function assertPersonaParity(cdp, sessionId, { label = '' } = {}) {
    const axes = await evaluate(cdp, sessionId, PERSONA_AXES_EXPR);
    const wrong = [];
    if (axes.devicePixelRatio !== PERSONA_DEVICE_SCALE_FACTOR) {
        wrong.push(`devicePixelRatio ${axes.devicePixelRatio} (want ${PERSONA_DEVICE_SCALE_FACTOR})`);
    }
    if (axes.prefersColorScheme !== PERSONA_PREFERS_COLOR_SCHEME) {
        wrong.push(`prefers-color-scheme ${axes.prefersColorScheme} (want ${PERSONA_PREFERS_COLOR_SCHEME})`);
    }
    if (wrong.length) {
        throw new Error(`persona parity${label ? ` [${label}]` : ''}: ${wrong.join('; ')}` +
            ` -- readings taken on an arm off the persona are not comparable`);
    }
    return axes;
}
