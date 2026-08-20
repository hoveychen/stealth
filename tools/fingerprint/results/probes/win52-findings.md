# Batch 18 / P1 — WebXR, measured on a headed Chrome 150 (macOS, no headset)

Probes: `probe-win52.js` (34 named + XRSystem: shapes, entry point, the two
constructible types), `probe-win53.js` (the 15 globals CreepJS's Chrome-115 key
table predates, plus a live `inline` session), `probe-win54.js` (the frame
loop), `probe-win55.js` (the collections and `end`).

Origin: `http://localhost:8731/` — WebXR is `[SecureContext]`, and localhost
counts, so no https server was needed. `window.isSecureContext` was `true`.

## 1. Chrome carries 50 `XR*` window globals, not 34

`creep-features-missing.json` lists 34 because CreepJS's key table is frozen at
Chrome 115. `Object.getOwnPropertyNames(window)` on Chrome 150 has 50:

    XRAnchor XRAnchorSet XRBoundedReferenceSpace XRCPUDepthInformation XRCamera
    XRCompositionLayer XRCubeLayer XRCylinderLayer XRDOMOverlayState
    XRDepthInformation XREquirectLayer XRFrame XRHand XRHitTestResult
    XRHitTestSource XRInputSource XRInputSourceArray XRInputSourceEvent
    XRInputSourcesChangeEvent XRJointPose XRJointSpace XRLayer XRLayerEvent
    XRLightEstimate XRLightProbe XRPlane XRPlaneSet XRPose XRProjectionLayer
    XRQuadLayer XRRay XRReferenceSpace XRReferenceSpaceEvent XRRenderState
    XRRigidTransform XRSession XRSessionEvent XRSpace XRSubImage XRSystem
    XRTransientInputHitTestResult XRTransientInputHitTestSource XRView
    XRViewerPose XRViewport XRVisibilityMaskChangeEvent XRWebGLBinding
    XRWebGLDepthInformation XRWebGLLayer XRWebGLSubImage

This engine has exactly one of them, `XRSystem`. Anything comparing window's own
keys against a real Chrome sees 49 missing, not 34.

## 2. `navigator.xr.requestSession('inline')` RESOLVES on a plain desktop

This is the finding that decides the shape of the batch. No headset, no
emulator, headed Chrome:

    isSessionSupported('inline')       -> resolved true
    isSessionSupported('immersive-vr') -> resolved false
    isSessionSupported('immersive-ar') -> resolved false
    isSessionSupported('nope')         -> TypeError, "not a valid enum value of
                                          type XRSessionMode"
    requestSession('inline')           -> resolved [object XRSession]
    requestSession('immersive-vr')     -> SecurityError, "requires user activation"

So the whole session / reference-space / frame / pose / view surface is
reachable from ordinary script on an ordinary machine. It cannot be stubbed as
"no device, everything rejects" — that is itself a fingerprint.

This engine today answers `false` to `isSessionSupported('inline')` and throws
`SecurityError: The operation is insecure` from every `requestSession`.

## 3. An inline session's `requestAnimationFrame` does not fire until a baseLayer is set

Measured twice (`probe-win53` saw the timeout, `probe-win54` isolated the
cause). With no `renderState.baseLayer`, `session.requestAnimationFrame(cb)`
never calls back — 5 s, while plain `window.requestAnimationFrame` fires
normally in the same page. Set `updateRenderState({baseLayer: new
XRWebGLLayer(session, gl)})` and the callback arrives on the next frame.

`updateRenderState` is **not** visible synchronously: right after the call
`session.renderState.baseLayer` is still `null`; inside the next frame callback
it is the layer. Same for `depthNear` (`0.1 -> 0.1` synchronously).

## 4. Inline defaults, on the record

    session.environmentBlendMode      "opaque"
    session.interactionMode           "screen-space"
    session.visibilityState           "visible"
    session.preferredReflectionFormat "rgba16f"
    session.maxRenderLayers           1
    session.enabledFeatures           ["viewer"]  (frozen Array, stable identity)
    session.inputSources              [object XRInputSourceArray], length 0, stable
    session.domOverlayState           null
    renderState.depthNear             0.1
    renderState.depthFar              1000
    renderState.inlineVerticalFieldOfView  1.5707963267948966  (pi/2)
    renderState.baseLayer             null
    renderState.layers                frozen Array, length 0

    depthUsage / depthDataFormat / depthType / depthActive
        -> InvalidStateError, "Depth sensing feature is not supported by the session."

Reference spaces: only `viewer` is granted. `local`, `local-floor`,
`bounded-floor`, `unbounded` all reject `NotSupportedError: This device does not
support the requested reference space type.`, and `nope` is a `TypeError` on the
enum.

Feature-gated requests refuse by name:

    requestHitTestSource                  NotSupportedError "Session does not support feature hit-test"
    requestHitTestSourceForTransientInput NotSupportedError "Session does not support feature hit-test"
    requestLightProbe                     NotSupportedError "Session does not support feature light-estimation"
    pauseDepthSensing / resumeDepthSensing (outside a frame)
                                          InvalidStateError "Not called from inside an active animation frame."
    pauseDepthSensing (inside a frame)    NotSupportedError "Depth sensing feature is not supported by the session."
    initiateRoomCapture                   returns a Promise (no sync throw)

## 5. The frame, the pose and the one view

Inside the callback, with a baseLayer:

    frame                       [object XRFrame], frame.session === session
    frame.predictedDisplayTime  undefined   (not on Chrome 150's XRFrame prototype)
    frame.trackedAnchors        [object XRAnchorSet], size 0, NEW OBJECT each read
    frame.detectedPlanes        [object XRPlaneSet], size 0
    getViewerPose(viewer)       [object XRViewerPose], emulatedPosition false,
                                views.length 1, views is a frozen Array
    viewerPose.transform.matrix identity
    getPose(viewer, viewer)     [object XRPose], identity, emulatedPosition false
    views[0]                    eye "none", index 0, isFirstPersonObserver false,
                                camera null, recommendedViewportScale null
    views[0].projectionMatrix   1,0,0,0, 0,1,0,0, 0,0,-1.0002,-1, 0,0,-0.20002,0
    views[0].transform.matrix   identity
    baseLayer.getViewport(view) [object XRViewport] 0,0,0,0
    baseLayer.framebuffer       null
    baseLayer framebuffer size  300x150  (the untouched canvas default)
    baseLayer.antialias         true
    baseLayer.ignoreDepthValues true

The projection matrix is the standard perspective matrix for fovy = pi/2,
aspect = 1, near = 0.1, far = 1000: `-(f+n)/(f-n) = -1.0002`, `-2fn/(f-n) =
-0.20002`. It follows the renderState, so it is derived, not a constant.

The `XRFrame` stays usable after the callback returns — `getViewerPose` outside
the callback still answered. Second frame: new `XRFrame` object, same session,
time advances.

Argument checking inside the frame is uniform Blink WebIDL:

    getViewerPose()                    TypeError "1 argument required, but only 0 present."
    getPose(viewer)                    TypeError "2 arguments required, but only 1 present."
    getLightEstimate({})               TypeError "parameter 1 is not of type 'XRLightProbe'."
    getHitTestResults({})              TypeError "parameter 1 is not of type 'XRHitTestSource'."
    getJointPose({}, viewer)           TypeError "parameter 1 is not of type 'XRJointSpace'."
    getDepthInformation(view)          NotSupportedError "Depth sensing feature is not supported by the session."
    fillPoses([], viewer, Float32Array(16))   -> true
    fillJointRadii([], Float32Array(1))       TypeError "Buffer sizes must be equal"
    createAnchor(transform, space)     returns a Promise

## 6. `session.end()` never completes on an inline session

Measured with a 10 s window and a 100 ms interval ticking alongside (105 ticks
observed, so the task queue was healthy):

    session.end()            returns [object Promise]
    that promise             STILL PENDING after 10 s
    `end` event              never dispatched (neither onend nor addEventListener)
    session.visibilityState  still "visible" afterwards
    session.end() again      InvalidStateError "XRSession has already ended."
    session.requestAnimationFrame(cb) afterwards -> returns handle 0, never fires
    session.requestReferenceSpace / updateRenderState afterwards
                             InvalidStateError "XRSession has already ended."
    new XRWebGLLayer(session, gl) afterwards
                             InvalidStateError "Cannot create an XRWebGLLayer for
                             an XRSession which has already ended."

So the session flips to ended synchronously, but the promise and the event never
arrive. Odd, and not guessable — worth reproducing exactly.

## 7. `XRRigidTransform` and `XRRay` are the only two constructible types

`XRRigidTransform`:

    new XRRigidTransform()                position 0,0,0,1  orientation 0,0,0,1
    .matrix                               Float32Array, identity, STABLE identity
    .position / .orientation              DOMPointReadOnly, stable identity
    .inverse                              stable identity; t.inverse.inverse === t
    new XRRigidTransform({x:1,y:2,z:3})   position 1,2,3,1
      .matrix                             column-major, translation in 12..14
    orientation normalisation             {3,0,0,4} -> 0.6,0,0,0.8 (double precision)
    {x:0,y:0,z:1,w:1}                     -> 0,0,0.7071067811865475,0.7071067811865475
    position with w !== 1                 TypeError "W component of position must be 1.0"
    zero-length orientation               InvalidStateError "Orientation's length cannot be 0"
    non-finite member                     TypeError "Position and Orientation must consist
                                          of only finite values"
    non-dictionary argument               TypeError "The provided value is not of type
                                          'DOMPointInit'."

`XRRay`:

    new XRRay()                           origin 0,0,0,1  direction 0,0,-1,0
    .matrix                               Float32Array, identity for the default ray
    .origin / .direction                  DOMPointReadOnly, stable identity
    direction normalisation               {0,3,4} -> 0,0.6000000238418579,0.800000011920929
                                          (FLOAT32 precision, unlike the transform's double)
    zero-length direction                 TypeError "Unable to normalize vector of length 0."
    origin w !== 1                        TypeError "Origin's `w` component must be set to 1.0f!"
    direction w !== 0                     TypeError "Direction's `w` component must be set to 0.0f!"
    new XRRay(rigidTransform)             origin and direction taken from the transform;
                                          a second argument is then ignored
    new XRRay({}, {x:1,y:0,z:0}).matrix   0,0,1,0, 0,1,0,0, -1,0,0,0, 0,0,0,1

The precision difference between the two is real and repeatable: the transform
normalises in double, the ray in float32.

## 8. Shapes

Every prototype carries an own `Symbol.toStringTag` equal to the interface name,
every accessor is `[ec-]` (enumerable, configurable, no writable), every method
is `[ecw]`. Constructor arity is 0 for the illegal-constructor types, 2 for the
five event subclasses and for `XRWebGLBinding` / `XRWebGLLayer`. All the illegal
ones throw `TypeError: Failed to construct 'X': Illegal constructor`.

Prototype chains that are not plain `Object`:

    XRBoundedReferenceSpace  <- XRReferenceSpace <- XRSpace <- EventTarget
    XRReferenceSpace         <- XRSpace <- EventTarget
    XRJointSpace             <- XRSpace <- EventTarget
    XRSpace / XRSession / XRLayer / XRLightProbe / XRSystem  <- EventTarget
    XRViewerPose / XRJointPose  <- XRPose
    XRCPUDepthInformation / XRWebGLDepthInformation  <- XRDepthInformation
    XRWebGLLayer / XRCompositionLayer  <- XRLayer <- EventTarget
    XRCubeLayer / XRCylinderLayer / XREquirectLayer / XRProjectionLayer /
      XRQuadLayer  <- XRCompositionLayer <- XRLayer <- EventTarget
    XRWebGLSubImage  <- XRSubImage
    XRSessionEvent / XRInputSourceEvent / XRInputSourcesChangeEvent /
      XRReferenceSpaceEvent / XRLayerEvent / XRVisibilityMaskChangeEvent  <- Event

`XRWebGLLayer` is the only one with a static: `getNativeFramebufferScaleFactor`,
arity 1, which answers `1` for a live inline session and
`TypeError: parameter 1 is not of type 'XRSession'.` for anything else.

The per-prototype member lists are in `/tmp/win52-chrome.json` and
`/tmp/win53-chrome.json` and are reproduced verbatim in the Zig tests.

## 9. The collections

    XRAnchorSet / XRPlaneSet   set-like: size, entries, forEach, has, keys, values,
                               @@iterator === values, brand "[object XRAnchorSet]".
                               NOT instanceof Set. values() brands as
                               "[object XRAnchorSet Iterator]".
                               has(nonAnchor) -> TypeError "parameter 1 is not of
                               type 'XRAnchor'."
                               forEach() with no argument -> TypeError "1 argument
                               required, but only 0 present."
    XRInputSourceArray         array-like: length, entries, keys, values, forEach,
                               @@iterator === values. NOT an Array. entries()
                               brands as "[object Array Iterator]" (note the
                               difference from the set-likes). forEach() with no
                               argument -> plain "TypeError: undefined is not a
                               function", i.e. no WebIDL arity check.
                               Indexed access on an empty one: undefined, and
                               getOwnPropertyNames is empty.
    XRHand                     map-like: size, get, entries, forEach, keys, values,
                               @@iterator === entries (not values).

## 10. Neighbours this family plugs into

    Navigator.prototype.xr                   accessor [ec-]           — present here
    window.onbeforexrselect                  exists in Chrome         — exists here
    HTMLElement.prototype.onbeforexrselect   exists in Chrome         — MISSING here (G20)
    WebGLRenderingContext.prototype.makeXRCompatible   function        — MISSING here
    WebGL2RenderingContext.prototype.makeXRCompatible  function        — MISSING here
    getContextAttributes().xrCompatible      false                    — false here already
    gl.makeXRCompatible() on a plain canvas  rejects InvalidStateError
                                             "An attempt was made to use an object
                                             that is not, or is no longer, usable."
