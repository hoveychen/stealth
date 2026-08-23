// The refusal the 92 members with a too-small `.length` are not giving.
//
// probe-operation-arity.js compares every member's `.length` across engines and
// found 92 where this engine reports fewer required arguments than Chrome does.
// `.length` is only the symptom; this probe reads the consequence, which is what
// a detector actually sees: Chrome refuses the short call and this engine
// returns quietly.
//
// All 92 are here, not a representative each, because the sentence names the
// operation and the interface that declares it -- so there are 92 distinct
// sentences and no way to derive one from another. A handful of partial calls
// come along at the end: the members wanting 2 or 3 arguments have to be seen
// refusing a call that is short by one, not only one that is empty, because
// "but only 1 present." is the half of the wording a zero-argument call never
// exercises.
//
// A promise-returning operation does not throw. It rejects, and its `.length`
// and its refusal come apart -- `pc.setRemoteDescription()` is the one that
// matters here. The runner awaits, so those read as `rejected: ...`.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-arity-gaps.js \
//       http://127.0.0.1:9721/ --headed
(async () => {
    const out = {};

    // A receiver per interface. Anything that cannot be built at all is
    // reported as such rather than skipped silently: a missing receiver is a
    // coverage gap, not a match.
    const build = (fn) => { try { return fn(); } catch (e) { return { __err: `${e.name}: ${e.message}` }; } };

    const canvas = document.createElement('canvas');
    const receivers = {
        Node: build(() => document.createElement('div')),
        Element: build(() => document.createElement('div')),
        Document: build(() => document),
        DocumentFragment: build(() => document.createDocumentFragment()),
        DOMImplementation: build(() => document.implementation),
        Selection: build(() => getSelection()),
        DataTransferItem: build(() => {
            const dt = new DataTransfer();
            dt.items.add('x', 'text/plain');
            return dt.items[0];
        }),
        WebGLRenderingContext: build(() => canvas.getContext('webgl')),
        WebGL2RenderingContext: build(() => document.createElement('canvas').getContext('webgl2')),
        RTCPeerConnection: build(() => new RTCPeerConnection()),
        RTCRtpSender: build(() => new RTCPeerConnection().addTransceiver('audio').sender),
        RTCRtpTransceiver: build(() => new RTCPeerConnection().addTransceiver('audio')),
    };

    // The 92, grouped by the interface whose prototype declares them. The two
    // WebGL contexts share most names; each is bound separately, so each is
    // measured separately.
    const gl1 = [
        'getActiveAttrib', 'getActiveUniform', 'getAttachedShaders', 'getAttribLocation',
        'getProgramInfoLog', 'getProgramParameter', 'getShaderInfoLog', 'getShaderParameter',
        'getShaderSource', 'getUniform', 'getUniformLocation', 'isBuffer', 'isFramebuffer',
        'isProgram', 'isRenderbuffer', 'isShader', 'isTexture',
    ];
    const gl2 = [
        'clientWaitSync', 'getActiveAttrib', 'getActiveUniform', 'getActiveUniformBlockName',
        'getActiveUniformBlockParameter', 'getActiveUniforms', 'getAttachedShaders',
        'getAttribLocation', 'getFragDataLocation', 'getProgramInfoLog', 'getProgramParameter',
        'getQueryParameter', 'getSamplerParameter', 'getShaderInfoLog', 'getShaderParameter',
        'getShaderSource', 'getSyncParameter', 'getTransformFeedbackVarying', 'getUniform',
        'getUniformBlockIndex', 'getUniformIndices', 'getUniformLocation', 'isBuffer',
        'isFramebuffer', 'isProgram', 'isQuery', 'isRenderbuffer', 'isSampler', 'isShader',
        'isSync', 'isTexture', 'isTransformFeedback', 'isVertexArray',
    ];
    const groups = {
        Node: ['contains', 'isDefaultNamespace', 'isSameNode', 'lookupNamespaceURI', 'lookupPrefix'],
        Element: [
            'animate', 'getAttributeNS', 'getAttributeNodeNS', 'getElementsByTagNameNS',
            'hasAttributeNS', 'hasPointerCapture', 'releasePointerCapture', 'removeAttributeNS',
            'setAttributeNS', 'setPointerCapture',
        ],
        Document: ['createElementNS', 'evaluate', 'getElementById', 'getElementsByTagNameNS'],
        DocumentFragment: ['getElementById'],
        DOMImplementation: ['createDocumentType'],
        DataTransferItem: ['getAsString'],
        Selection: ['collapse', 'setPosition'],
        RTCPeerConnection: [
            'addStream', 'addTrack', 'addTransceiver', 'createDTMFSender', 'removeStream',
            'removeTrack', 'setRemoteDescription',
        ],
        RTCRtpSender: ['replaceTrack', 'setParameters'],
        RTCRtpTransceiver: ['setCodecPreferences', 'setHeaderExtensionsToNegotiate'],
        WebGLRenderingContext: gl1,
        WebGL2RenderingContext: gl2,
    };

    // Call `member` on its receiver with `args` and describe what came back.
    // A thenable is awaited: the refusal of a promise-returning operation is a
    // rejection, not a throw.
    const at = async (label, iface, member, args) => {
        const recv = receivers[iface];
        if (recv && recv.__err) { out[label] = `no receiver -> ${recv.__err}`; return; }
        if (!recv) { out[label] = 'no receiver -> null'; return; }
        const fn = recv[member];
        if (typeof fn !== 'function') { out[label] = `absent (typeof ${typeof fn})`; return; }
        try {
            const v = fn.apply(recv, args);
            if (v && typeof v.then === 'function') {
                try { const r = await v; out[label] = 'resolved -> ' + String(r); }
                catch (e) { out[label] = `rejected: ${e.name}: ${e.message}`; }
                return;
            }
            out[label] = 'no throw -> ' + String(v);
        } catch (e) {
            out[label] = `${e.name}: ${e.message}`;
        }
    };

    for (const [iface, members] of Object.entries(groups)) {
        for (const member of members) {
            // `.length` next to the sentence: a count checked before conversion
            // is only right if the count reported is WebIDL's.
            const proto = globalThis[iface] && globalThis[iface].prototype;
            const fn = proto && proto[member];
            out[`${iface}.${member}.length`] = typeof fn === 'function' ? fn.length : 'absent';
            await at(`${iface}.${member}()`, iface, member, []);
        }
    }

    // Short by one, not empty. Every count above 1 among the 92, so the
    // "but only 1 present." (and "only 2") half of the wording is on record.
    await at("Element.setAttributeNS('x')", 'Element', 'setAttributeNS', ['x']);
    await at("Element.setAttributeNS('x','y')", 'Element', 'setAttributeNS', ['x', 'y']);
    await at("Element.getAttributeNS('x')", 'Element', 'getAttributeNS', ['x']);
    await at("Element.getAttributeNodeNS('x')", 'Element', 'getAttributeNodeNS', ['x']);
    await at("Element.hasAttributeNS('x')", 'Element', 'hasAttributeNS', ['x']);
    await at("Element.removeAttributeNS('x')", 'Element', 'removeAttributeNS', ['x']);
    await at("Element.getElementsByTagNameNS('x')", 'Element', 'getElementsByTagNameNS', ['x']);
    await at("Document.createElementNS('x')", 'Document', 'createElementNS', ['x']);
    await at("Document.evaluate('x')", 'Document', 'evaluate', ['x']);
    await at("Document.getElementsByTagNameNS('x')", 'Document', 'getElementsByTagNameNS', ['x']);
    await at("DOMImplementation.createDocumentType('x')", 'DOMImplementation', 'createDocumentType', ['x']);
    await at("DOMImplementation.createDocumentType('x','y')", 'DOMImplementation', 'createDocumentType', ['x', 'y']);
    await at('WebGL.getAttribLocation(p)', 'WebGLRenderingContext', 'getAttribLocation', [null]);
    await at('WebGL.getUniformLocation(p)', 'WebGLRenderingContext', 'getUniformLocation', [null]);
    await at('WebGL2.clientWaitSync(s)', 'WebGL2RenderingContext', 'clientWaitSync', [null]);
    await at('WebGL2.clientWaitSync(s,0)', 'WebGL2RenderingContext', 'clientWaitSync', [null, 0]);
    await at('WebGL2.getActiveUniforms(p)', 'WebGL2RenderingContext', 'getActiveUniforms', [null]);
    await at('WebGL2.getActiveUniforms(p,[])', 'WebGL2RenderingContext', 'getActiveUniforms', [null, []]);

    return out;
})();
