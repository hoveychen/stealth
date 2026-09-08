// Census of every name Cloudflare's guard reads, taken from the disassembled
// bytecode (op 239/58/254/233 carry the name inline). See the README section
// "Naming all 48 handlers" and scratch/cfvm/names.clean.json.
//
// For each name this reports WHERE it lives -- globalThis, the prototype of any
// global constructor, or one of a set of concrete instances -- and its typeof.
// The guard reads these names off objects we cannot resolve statically, so the
// census asks the only question that does not need that: does this engine put
// the name in the same places Chrome does, with the same kind of value.
(() => {
    const NAMES = ["Array","AudioContext","BigInt","Blob","BroadcastChannel","CanvasGradient","CanvasRenderingContext2D","Crypto","DOCUMENT_POSITION_DISCONNECTED","DOCUMENT_POSITION_FOLLOWING","DOMParser","DONE","Date","DateTimeFormat","Document","Element","Event","EventTarget","FontFace","Function","GPU","HEADERS_RECEIVED","HTMLCanvasElement","HTMLElement","Intl","JSON","Keyboard","KeyboardEvent","LOADING","Math","MediaCapabilities","MediaDevices","MediaSource","MessageEvent","MouseEvent","MutationObserver","Navigator","NavigatorUAData","NetworkInformation","Node","Number","OPENED","Object","OfflineAudioContext","Performance","PerformanceObserver","Permissions","PointerEvent","Promise","RTCPeerConnection","RTCRtpReceiver","ReadableStream","Screen","SpeechSynthesis","String","SubtleCrypto","Summarizer","TextEncoder","TrustedTypePolicy","TrustedTypePolicyFactory","UNSENT","URL","Uint8Array","WebGL2RenderingContext","WebGLRenderingContext","Window","Worker","XMLHttpRequest","_cf_chl_opt","addColorStop","addEventListener","all","appendChild","apply","arc","attachShadow","availability","beginPath","bezierCurveTo","bind","body","bufferData","call","catch","charAt","check","clearTimeout","click","colno","compareDocumentPosition","console","count","countReset","create","createComment","createDataChannel","createElement","createHTML","createObjectURL","createOffer","createPolicy","createRadialGradient","createScript","createScriptURL","crypto","debug","decodingInfo","defaultSelected","defineProperty","digest","dir","dirName","dirxml","dispatchEvent","display","document","documentElement","draggable","ellipse","encode","enumerateDevices","env","error","eval","fetch","filename","fill","fillText","firstChild","floor","fonts","from","fromCodePoint","get","getBattery","getBoundingClientRect","getCapabilities","getComputedStyle","getContext","getEntries","getEntriesByType","getExtension","getGamepads","getHighEntropyValues","getImageData","getLayoutMap","getOwnPropertyDescriptor","getOwnPropertyNames","getParameter","getPrototypeOf","getRandomValues","getRootNode","getShaderPrecisionFormat","getSupportedExtensions","getTimezoneOffset","getVoices","hasFocus","head","includes","indexOf","info","innerHTML","innerText","isTypeSupported","join","keys","label","left","length","lineno","load","log","map","mark","matchMedia","max","maxLength","message","min","mode","moveTo","navigator","now","observe","once","options","outerHTML","padStart","parse","parseFromString","parseInt","pipeTo","pop","postMessage","preventDefault","process","quadraticCurveTo","query","querySelector","querySelectorAll","race","random","randomUUID","readPixels","reason","remove","removeChild","removeEventListener","requestAdapter","resolve","resolvedOptions","revokeObjectURL","right","round","scrollIntoView","selected","selectedIndex","send","sendBeacon","setAttribute","setInterval","setLocalDescription","setPrototypeOf","setTimeout","shadowRoot","spellcheck","split","stringify","stroke","strokeText","structuredClone","style","subtle","table","terminate","test","then","toDataURL","toJSON","toLocaleString","toLowerCase","toString","top","trace","translate","value","warn","width","x","y"];

    const hosts = [];
    const add = (label, obj) => { if (obj && (typeof obj === "object" || typeof obj === "function")) hosts.push([label, obj]); };
    add("global", globalThis);
    for (const k of Object.getOwnPropertyNames(globalThis)) {
        let v; try { v = globalThis[k]; } catch (e) { continue; }
        if (typeof v === "function" && v.prototype) add(k + ".prototype", v.prototype);
    }
    const mk = (t) => { try { return document.createElement(t); } catch (e) { return null; } };
    add("navigator", navigator);
    for (const k of ["userAgentData", "connection", "mediaCapabilities", "mediaDevices",
                     "permissions", "gpu", "keyboard", "storage", "serviceWorker", "plugins"]) {
        try { add("navigator." + k, navigator[k]); } catch (e) { /* absent */ }
    }
    add("screen", screen);
    add("document", document);
    add("documentElement", document.documentElement);
    add("performance", performance);
    try { add("crypto", crypto); add("crypto.subtle", crypto.subtle); } catch (e) { /* absent */ }
    add("location", location);
    add("Intl", Intl); add("Math", Math); add("JSON", JSON); add("console", console);
    add("Object", Object); add("Reflect", typeof Reflect !== "undefined" ? Reflect : null);
    add("div", mk("div")); add("input", mk("input")); add("option", mk("option"));
    add("textarea", mk("textarea")); add("canvas", mk("canvas"));
    try { add("ctx2d", mk("canvas").getContext("2d")); } catch (e) { /* absent */ }
    try { add("webgl", mk("canvas").getContext("webgl")); } catch (e) { /* absent */ }
    try { add("xhr", new XMLHttpRequest()); } catch (e) { /* absent */ }

    const out = {};
    for (const n of NAMES) {
        const where = [];
        let kind = "";
        for (const [label, obj] of hosts) {
            let has = false;
            try { has = n in obj; } catch (e) { continue; }
            if (!has) continue;
            where.push(label);
            if (!kind) { try { kind = typeof obj[n]; } catch (e) { kind = "throw"; } }
        }
        out[n] = where.length ? kind + " @ " + where.join("|") : "ABSENT";
    }
    return out;
})()
