// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// WebIDL [SecureContext]: the global names a browser only exposes to a document
// whose origin is potentially trustworthy.
//
// Measured on a headed Chrome 151 by serving one page from two origins that
// differ in nothing but host trustworthiness -- http://localhost:8777 and
// http://192.168.68.78:8777, same scheme, same server, same port:
//
//   window realm, Object.getOwnPropertyNames(window).length
//                                             1237 secure     985 insecure
//   worker realm, Object.getOwnPropertyNames(self).length
//                                              336 secure     243 insecure
//
// 252 names in the window realm. This engine answered 1167 either way -- it
// gated nothing -- and 234 of Chrome's 252 were names it had, which was this
// list; ClipboardChangeEvent has since been added to the surface and it is one
// of Chrome's gated names too, so the list is 235 and the not-implemented
// remainder 17; FileSystemSyncAccessHandle has since been added as well, making
// it 236 and the remainder 16; BarcodeDetector, PressureObserver and Summarizer
// have since been added too, making it 239 and the remainder 13. That remainder
// belongs to the separate what-are-we-missing count, not here.
//
// navigator.cpuPerformance is gated as well but is not part of that 252: it is
// a Navigator member, not a name on the window, so it has its own list below and
// its own reading.
//
// One list covers both realms. [SecureContext] is an attribute of the
// interface, not of the realm, so a name gated in a window is gated in a worker
// too -- Chrome's worker gated set is smaller (93) only because a worker
// exposes fewer interfaces to begin with, and the 8 of them this engine leaked
// are a subset of the list below (measured).
//
// Kept as names rather than as a flag on each interface's Meta because the
// ground truth is one Chrome reading of the whole surface, so a list diffs
// against the probe output directly. Snapshot asserts at comptime that every
// name here is one this engine actually defines, so a typo is a build error
// rather than a silently ungated interface.

const std = @import("std");

// Interface objects and WebIDL namespaces: own properties of the global, and of
// nothing else, so the gate deletes them from there.
pub const gated_interfaces = [_][:0]const u8{
    "AbsoluteOrientationSensor",         "Accelerometer",                   "AudioDecoder",                         "AudioEncoder",
    "AudioPlaybackStats",                "AudioWorklet",                    "AuthenticatorAssertionResponse",       "AuthenticatorAttestationResponse",
    "AuthenticatorResponse",             "BarcodeDetector",                 "BatteryManager",                       "Bluetooth",
    "BluetoothCharacteristicProperties", "BluetoothDevice",                 "BluetoothRemoteGATTCharacteristic",    "BluetoothRemoteGATTDescriptor",
    "BluetoothRemoteGATTServer",         "BluetoothRemoteGATTService",      "Cache",                                "CacheStorage",
    "CaptureController",                 "Clipboard",                       "ClipboardChangeEvent",                 "ClipboardItem",
    "CookieChangeEvent",                 "CookieStore",                     "CookieStoreManager",                   "Credential",
    "CredentialsContainer",              "CryptoKey",                       "DeviceMotionEvent",                    "DeviceMotionEventAcceleration",
    "DeviceMotionEventRotationRate",     "DeviceOrientationEvent",          "DevicePosture",                        "EyeDropper",
    "FederatedCredential",               "FileSystemDirectoryHandle",       "FileSystemFileHandle",                 "FileSystemHandle",
    "FileSystemSyncAccessHandle",        "FileSystemWritableFileStream",    "FontData",                             "GPU",
    "GPUAdapter",                        "GPUAdapterInfo",                  "GPUBindGroup",                         "GPUBindGroupLayout",
    "GPUBuffer",                         "GPUBufferUsage",                  "GPUCanvasContext",                     "GPUColorWrite",
    "GPUCommandBuffer",                  "GPUCommandEncoder",               "GPUCompilationInfo",                   "GPUCompilationMessage",
    "GPUComputePassEncoder",             "GPUComputePipeline",              "GPUDevice",                            "GPUDeviceLostInfo",
    "GPUError",                          "GPUExternalTexture",              "GPUInternalError",                     "GPUMapMode",
    "GPUOutOfMemoryError",               "GPUPipelineError",                "GPUPipelineLayout",                    "GPUQuerySet",
    "GPUQueue",                          "GPURenderBundle",                 "GPURenderBundleEncoder",               "GPURenderPassEncoder",
    "GPURenderPipeline",                 "GPUSampler",                      "GPUShaderModule",                      "GPUShaderStage",
    "GPUSupportedFeatures",              "GPUSupportedLimits",              "GPUTexture",                           "GPUTextureUsage",
    "GPUTextureView",                    "GPUUncapturedErrorEvent",         "GPUValidationError",                   "GravitySensor",
    "Gyroscope",                         "HID",                             "HIDConnectionEvent",                   "HIDDevice",
    "HIDInputReportEvent",               "IdentityCredential",              "IdleDetector",                         "ImageCapture",
    "ImageDecoder",                      "ImageTrack",                      "ImageTrackList",                       "Keyboard",
    "KeyboardLayoutMap",                 "LinearAccelerationSensor",        "Lock",                                 "LockManager",
    "MIDIAccess",                        "MIDIConnectionEvent",             "MIDIInput",                            "MIDIInputMap",
    "MIDIMessageEvent",                  "MIDIOutput",                      "MIDIOutputMap",                        "MIDIPort",
    "MediaDeviceInfo",                   "MediaDevices",                    "MediaKeyMessageEvent",                 "MediaKeySession",
    "MediaKeyStatusMap",                 "MediaKeySystemAccess",            "MediaKeys",                            "NavigationPreloadManager",
    "NavigatorLogin",                    "NavigatorManagedData",            "OTPCredential",                        "OrientationSensor",
    "PasswordCredential",                "PaymentAddress",                  "PaymentManager",                       "PaymentMethodChangeEvent",
    "PaymentRequest",                    "PaymentRequestUpdateEvent",       "PaymentResponse",                      "Presentation",
    "PresentationAvailability",          "PresentationConnection",          "PresentationConnectionAvailableEvent", "PresentationConnectionCloseEvent",
    "PresentationConnectionList",        "PresentationReceiver",            "PresentationRequest",                  "PressureObserver",
    "ProtectedAudience",                 "PublicKeyCredential",             "RelativeOrientationSensor",            "ScreenDetailed",
    "ScreenDetails",                     "Sensor",                          "SensorErrorEvent",                     "Serial",
    "SerialPort",                        "ServiceWorker",                   "ServiceWorkerContainer",               "ServiceWorkerRegistration",
    "SpeechRecognitionPhrase",           "StorageBucket",                   "StorageBucketManager",                 "StorageManager",
    "SubtleCrypto",                      "Summarizer",                      "USB",                                  "USBAlternateInterface",
    "USBConfiguration",                  "USBConnectionEvent",              "USBDevice",                            "USBEndpoint",
    "USBInTransferResult",               "USBInterface",                    "USBIsochronousInTransferPacket",       "USBIsochronousInTransferResult",
    "USBIsochronousOutTransferPacket",   "USBIsochronousOutTransferResult", "USBOutTransferResult",                 "VideoDecoder",
    "VideoEncoder",                      "VirtualKeyboard",                 "WGSLLanguageFeatures",                 "WakeLock",
    "WakeLockSentinel",                  "WebTransport",                    "WebTransportBidirectionalStream",      "WebTransportDatagramDuplexStream",
    "WebTransportError",                 "Worklet",                         "XRAnchor",                             "XRAnchorSet",
    "XRBoundedReferenceSpace",           "XRCPUDepthInformation",           "XRCamera",                             "XRCompositionLayer",
    "XRCubeLayer",                       "XRCylinderLayer",                 "XRDOMOverlayState",                    "XRDepthInformation",
    "XREquirectLayer",                   "XRFrame",                         "XRHand",                               "XRHitTestResult",
    "XRHitTestSource",                   "XRInputSource",                   "XRInputSourceArray",                   "XRInputSourceEvent",
    "XRInputSourcesChangeEvent",         "XRJointPose",                     "XRJointSpace",                         "XRLayer",
    "XRLayerEvent",                      "XRLightEstimate",                 "XRLightProbe",                         "XRPlane",
    "XRPlaneSet",                        "XRPose",                          "XRProjectionLayer",                    "XRQuadLayer",
    "XRRay",                             "XRReferenceSpace",                "XRReferenceSpaceEvent",                "XRRenderState",
    "XRRigidTransform",                  "XRSession",                       "XRSessionEvent",                       "XRSpace",
    "XRSubImage",                        "XRSystem",                        "XRTransientInputHitTestResult",        "XRTransientInputHitTestSource",
    "XRView",                            "XRViewerPose",                    "XRViewport",                           "XRVisibilityMaskChangeEvent",
    "XRWebGLBinding",                    "XRWebGLDepthInformation",         "XRWebGLLayer",                         "XRWebGLSubImage",
};

// Window members. In this engine these are own properties of the global *and*
// of the Window interface prototype object -- measured: deleting only the
// global's copy left 'caches' in window true -- so the gate walks the prototype
// chain for them. Chrome has them on the global alone.
pub const gated_members = [_][:0]const u8{
    "caches",                      "cookieStore",        "getScreenDetails", "ondevicemotion",      "ondeviceorientation",
    "ondeviceorientationabsolute", "onpointerrawupdate", "queryLocalFonts",  "showDirectoryPicker", "showOpenFilePicker",
    "showSaveFilePicker",
};

// Navigator members. Unlike the two lists above these are reached through the
// `Navigator` interface object rather than off the global -- Navigator.prototype
// is not on the window's prototype chain -- so they get their own pass, the same
// way Context.hideWebMcpSurface reaches `modelContext`.
//
// Measured the same way as the rest: navigator.cpuPerformance is 4 from
// http://127.0.0.1:13777 and undefined from http://192.168.40.29:13777 on a
// headed Chrome 152.
pub const gated_navigator_members = [_][:0]const u8{
    "cpuPerformance",
};

const testing = @import("../../testing.zig");

test "secure_context: lists are sorted and disjoint" {
    for (gated_interfaces[1..], 0..) |name, i| {
        try testing.expect(std.mem.order(u8, gated_interfaces[i], name) == .lt);
    }
    for (gated_members[1..], 0..) |name, i| {
        try testing.expect(std.mem.order(u8, gated_members[i], name) == .lt);
    }
    for (gated_members) |m| {
        for (gated_interfaces) |i| {
            try testing.expect(std.mem.eql(u8, m, i) == false);
        }
    }
    for (gated_navigator_members[1..], 0..) |name, i| {
        try testing.expect(std.mem.order(u8, gated_navigator_members[i], name) == .lt);
    }
    try testing.expectEqual(239, gated_interfaces.len + gated_members.len);
    try testing.expectEqual(1, gated_navigator_members.len);
}
