// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// The service objects hanging off navigator that are plain interfaces (no
// EventTarget in their chain). Chrome 150 puts 83 names on Navigator.prototype
// in a secure context; every one of these was missing here, and a missing name
// is as readable as a wrong value — browserleaks enumerates the prototype
// directly and CreepJS counts what it can't find.
//
// Shapes, brands, argument counts and return values were all measured on a
// headed Chrome 150 over http://localhost (Chrome treats localhost as a secure
// origin, which is what unlocks the other 47 names). Nothing here is recalled
// from the specs: where a value is a stub it says so and says why.
//
// The declaration order inside each JsApi is Chrome's own
// `Object.getOwnPropertyNames(X.prototype)` order, not alphabetical — the order
// is itself a hashable surface.

const std = @import("std");

const js = @import("../../js/js.zig");
const mime = @import("../media/mime.zig");
const chrome_sdp = @import("../webrtc/chrome_sdp.zig");
const Frame = @import("../../Frame.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Scheduling,
        UserActivation,
        Geolocation,
        ProtectedAudience,
        CredentialsContainer,
        NavigatorLogin,
        MediaCapabilities,
        MediaSession,
        Presentation,
        GPU,
        WGSLLanguageFeatures,
        WGSLLanguageFeatures.KeyIterator,
        WGSLLanguageFeatures.ValueIterator,
        WGSLLanguageFeatures.EntryIterator,
    };
}

pub const Scheduling = struct {
    _pad: bool = false,

    const IsInputPendingOptions = struct {
        includeContinuous: bool = false,
    };

    // Chrome answers false on a page with no queued input, with and without the
    // dictionary (measured). We never queue input at all.
    pub fn isInputPending(_: *const Scheduling, _: ?IsInputPendingOptions) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Scheduling);

        pub const Meta = struct {
            pub const name = "Scheduling";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const isInputPending = bridge.function(Scheduling.isInputPending, .{});
    };
};

pub const UserActivation = struct {
    _pad: bool = false,

    // Both false until a gesture reaches the page, which is what Chrome reports
    // on load. Nothing here ever synthesises one.
    pub fn getHasBeenActive(_: *const UserActivation) bool {
        return false;
    }

    pub fn getIsActive(_: *const UserActivation) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(UserActivation);

        pub const Meta = struct {
            pub const name = "UserActivation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const hasBeenActive = bridge.accessor(UserActivation.getHasBeenActive, null, .{});
        pub const isActive = bridge.accessor(UserActivation.getIsActive, null, .{});
    };
};

pub const Geolocation = struct {
    // Chrome's watch ids are a 1-based counter (measured: two calls in a row
    // returned 1 then 2).
    _next_watch_id: u32 = 0,

    const PositionOptions = struct {
        enableHighAccuracy: bool = false,
        timeout: ?u32 = null,
        maximumAge: ?u32 = null,
    };

    // Neither callback is ever invoked. On the reference Chrome the permission
    // request stayed pending and no callback had fired after five seconds, so a
    // pending request is a state a real Chrome is observably in. We have no
    // position and won't invent either a fix or a denial: a fabricated location
    // is a worse tell than a permission prompt nobody answered.
    pub fn getCurrentPosition(
        _: *Geolocation,
        _: js.Function,
        _: ?js.Function,
        _: ?PositionOptions,
    ) void {}

    pub fn watchPosition(
        self: *Geolocation,
        _: js.Function,
        _: ?js.Function,
        _: ?PositionOptions,
    ) u32 {
        self._next_watch_id += 1;
        return self._next_watch_id;
    }

    pub fn clearWatch(_: *Geolocation, _: u32) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Geolocation);

        pub const Meta = struct {
            pub const name = "Geolocation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const clearWatch = bridge.function(Geolocation.clearWatch, .{});
        pub const getCurrentPosition = bridge.function(Geolocation.getCurrentPosition, .{});
        pub const watchPosition = bridge.function(Geolocation.watchPosition, .{});
    };
};

pub const ProtectedAudience = struct {
    _pad: bool = false,

    // Chrome 150's answer to queryFeatureSupport('*'), copied field-for-field in
    // its own key order.
    const Features = struct {
        adComponentsLimit: u32 = 40,
        deprecatedRenderURLReplacements: bool = true,
        reportingTimeout: bool = true,
        permitCrossOriginTrustedSignals: bool = true,
        realTimeReporting: bool = true,
        selectableReportingIds: bool = false,
        sellerNonce: bool = true,
        trustedSignalsKVv2: bool = true,
        maxGroupLifetimeMs: u64 = 2592000000,
    };

    const Support = union(enum) {
        all: Features,
        flag: bool,
        limit: u64,
    };

    // '*' returns the whole dictionary, a named feature returns just its value,
    // and an unknown name returns undefined (all three measured).
    pub fn queryFeatureSupport(_: *const ProtectedAudience, name: []const u8) ?Support {
        const features: Features = .{};
        if (std.mem.eql(u8, name, "*")) {
            return .{ .all = features };
        }
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                return switch (@typeInfo(field.type)) {
                    .bool => .{ .flag = @field(features, field.name) },
                    else => .{ .limit = @field(features, field.name) },
                };
            }
        }
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ProtectedAudience);

        pub const Meta = struct {
            pub const name = "ProtectedAudience";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const queryFeatureSupport = bridge.function(
            ProtectedAudience.queryFeatureSupport,
            .{ .null_as_undefined = true },
        );
    };
};

pub const CredentialsContainer = struct {
    _pad: bool = false,

    // We store no credentials, so get() finds none. Chrome resolves null for a
    // request that matches nothing, which is the same answer (measured).
    pub fn get(_: *const CredentialsContainer, _: ?js.Object, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }

    // Measured: create({}) rejects NotSupportedError ("Only exactly one of
    // 'password', 'federated', and 'publicKey' credential types are currently
    // supported."). We have no credential store to create into, so every call
    // lands on that same rejection rather than on an invented success.
    pub fn create(_: *const CredentialsContainer, _: ?js.Object, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    pub fn preventSilentAccess(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    // Chrome type-checks the argument against Credential, which no page can
    // construct here, so every call is the TypeError it measured as.
    pub fn store(_: *const CredentialsContainer, _: js.Value, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{
            .type_error = "Failed to execute 'store' on 'CredentialsContainer': parameter 1 is not of type 'Credential'.",
        });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CredentialsContainer);

        pub const Meta = struct {
            pub const name = "CredentialsContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const create = bridge.function(CredentialsContainer.create, .{});
        pub const get = bridge.function(CredentialsContainer.get, .{});
        pub const preventSilentAccess = bridge.function(CredentialsContainer.preventSilentAccess, .{});
        pub const store = bridge.function(CredentialsContainer.store, .{});
    };
};

pub const NavigatorLogin = struct {
    _pad: bool = false,

    // Records the caller's federated-login status for the browser's own account
    // chooser. There is no chooser here, so this resolves with nothing — which
    // is what Chrome resolves with too (measured).
    pub fn setStatus(_: *const NavigatorLogin, _: []const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigatorLogin);

        pub const Meta = struct {
            pub const name = "NavigatorLogin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const setStatus = bridge.function(NavigatorLogin.setStatus, .{});
    };
};

pub const MediaCapabilities = struct {
    _pad: bool = false,

    const Configuration = struct {
        type: []const u8 = "",
        audio: ?Track = null,
        video: ?Track = null,

        const Track = struct {
            contentType: []const u8 = "",
        };
    };

    // Chrome's key order, measured.
    const Info = struct {
        powerEfficient: bool,
        smooth: bool,
        supported: bool,
        keySystemAccess: ?bool = null,
    };

    // A WebRTC configuration names an RTP codec ("video/VP8"), not a container,
    // so it is answered from the same measured Chrome capability tables that
    // back RTCRtpSender/Receiver.getCapabilities rather than from the playback
    // MIME table. Sending and receiving have different codec lists.
    fn rtpSupports(sending: bool, content_type: []const u8) bool {
        const bare = std.mem.trim(
            u8,
            content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len],
            &std.ascii.whitespace,
        );
        const tables = if (sending)
            [_]chrome_sdp.Capabilities{ chrome_sdp.sender_audio, chrome_sdp.sender_video }
        else
            [_]chrome_sdp.Capabilities{ chrome_sdp.receiver_audio, chrome_sdp.receiver_video };

        for (tables) |table| {
            for (table.codecs) |codec| {
                if (std.ascii.eqlIgnoreCase(codec.mime_type, bare)) {
                    return true;
                }
            }
        }
        return false;
    }

    // Everything else comes from the same measured Chrome MIME table that backs
    // canPlayType and MediaSource.isTypeSupported (see media/mime.zig), so the
    // three can't contradict each other.
    fn supports(config: Configuration, sending: bool) bool {
        if (std.mem.eql(u8, config.type, "webrtc")) {
            var any = false;
            inline for (.{ config.audio, config.video }) |maybe_track| {
                if (maybe_track) |track| {
                    any = true;
                    if (!rtpSupports(sending, track.contentType)) {
                        return false;
                    }
                }
            }
            return any;
        }

        const api: mime.Api = if (std.mem.eql(u8, config.type, "media-source"))
            .media_source
        else if (std.mem.eql(u8, config.type, "record"))
            .media_recorder
        else
            .play;

        var any = false;
        inline for (.{ config.audio, config.video }) |maybe_track| {
            if (maybe_track) |track| {
                any = true;
                const ok = switch (api) {
                    .play => mime.canPlayType(track.contentType) != .no,
                    else => mime.isTypeSupported(api, track.contentType),
                };
                if (!ok) {
                    return false;
                }
            }
        }
        return any;
    }

    pub fn decodingInfo(_: *const MediaCapabilities, config: Configuration, exec: *const Execution) !js.Promise {
        const supported = supports(config, false);
        return exec.js.local.?.resolvePromise(Info{
            .powerEfficient = supported,
            .smooth = supported,
            .supported = supported,
        });
    }

    // Chrome called a supported WebRTC encode smooth but not power efficient
    // (measured), so encoding never claims power efficiency.
    pub fn encodingInfo(_: *const MediaCapabilities, config: Configuration, exec: *const Execution) !js.Promise {
        const supported = supports(config, true);
        return exec.js.local.?.resolvePromise(Info{
            .powerEfficient = false,
            .smooth = supported,
            .supported = supported,
        });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaCapabilities);

        pub const Meta = struct {
            pub const name = "MediaCapabilities";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const decodingInfo = bridge.function(MediaCapabilities.decodingInfo, .{});
        pub const encodingInfo = bridge.function(MediaCapabilities.encodingInfo, .{});
    };
};

pub const MediaSession = struct {
    _playback_state: PlaybackState = .none,

    const PlaybackState = enum { none, paused, playing };

    // MediaMetadata has no constructor here, so no page can hand us a valid
    // value and the getter stays at Chrome's own default of null. The setter
    // drops what it's given rather than throwing, which is what a WebIDL
    // attribute of a type we can't represent would do anyway.
    pub fn getMetadata(_: *const MediaSession) ?bool {
        return null;
    }

    pub fn setMetadata(_: *MediaSession, _: ?js.Value) void {}

    pub fn getPlaybackState(self: *const MediaSession) []const u8 {
        return @tagName(self._playback_state);
    }

    // A value outside the enum is dropped, not thrown on: measured, assigning
    // 'bogus' left Chrome's playbackState at 'none'.
    pub fn setPlaybackState(self: *MediaSession, state: []const u8) void {
        self._playback_state = std.meta.stringToEnum(PlaybackState, state) orelse return;
    }

    // No media pipeline to route these into; Chrome returns undefined from all
    // four regardless (measured).
    // The handler is nullable but not optional, so Chrome reports length 2.
    pub fn setActionHandler(_: *MediaSession, _: []const u8, _: js.Value) void {}

    pub fn setCameraActive(_: *MediaSession, _: bool) void {}

    pub fn setMicrophoneActive(_: *MediaSession, _: bool) void {}

    pub fn setPositionState(_: *MediaSession, _: ?js.Object) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaSession);

        pub const Meta = struct {
            pub const name = "MediaSession";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const metadata = bridge.accessor(MediaSession.getMetadata, MediaSession.setMetadata, .{});
        pub const playbackState = bridge.accessor(MediaSession.getPlaybackState, MediaSession.setPlaybackState, .{});
        pub const setActionHandler = bridge.function(MediaSession.setActionHandler, .{});
        pub const setCameraActive = bridge.function(MediaSession.setCameraActive, .{});
        pub const setMicrophoneActive = bridge.function(MediaSession.setMicrophoneActive, .{});
        pub const setPositionState = bridge.function(MediaSession.setPositionState, .{});
    };
};

pub const Presentation = struct {
    _pad: bool = false,

    // Both null with no presentation display around, as on the reference
    // Chrome. PresentationRequest has no constructor here, so nothing can set
    // defaultRequest to anything but null either.
    pub fn getDefaultRequest(_: *const Presentation) ?bool {
        return null;
    }

    pub fn setDefaultRequest(_: *Presentation, _: ?js.Value) void {}

    pub fn getReceiver(_: *const Presentation) ?bool {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Presentation);

        pub const Meta = struct {
            pub const name = "Presentation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const defaultRequest = bridge.accessor(Presentation.getDefaultRequest, Presentation.setDefaultRequest, .{});
        pub const receiver = bridge.accessor(Presentation.getReceiver, null, .{});
    };
};

pub const GPU = struct {
    // Allocated on first read rather than embedded: the JS identity map is
    // keyed by Zig address alone, and a struct's first-in-memory field shares
    // its owner's address — an embedded instance would come back branded as its
    // owner.
    _features: ?*WGSLLanguageFeatures = null,

    pub fn getWgslLanguageFeatures(self: *GPU, frame: *Frame) !*WGSLLanguageFeatures {
        if (self._features) |features| {
            return features;
        }
        const created = try frame._factory.create(WGSLLanguageFeatures{});
        self._features = created;
        return created;
    }

    // Fixed in every Chromium build on this platform; measured 'bgra8unorm'.
    pub fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "bgra8unorm";
    }

    // No WebGPU device to hand out. requestAdapter resolving null is the answer
    // a Chrome with no usable adapter gives, and implementing GPUAdapter would
    // mean inventing a GPU's limits — a far louder lie than having none.
    pub fn requestAdapter(_: *const GPU, _: ?js.Object, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPU);

        pub const Meta = struct {
            pub const name = "GPU";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const wgslLanguageFeatures = bridge.accessor(GPU.getWgslLanguageFeatures, null, .{});
        pub const getPreferredCanvasFormat = bridge.function(GPU.getPreferredCanvasFormat, .{});
        pub const requestAdapter = bridge.function(GPU.requestAdapter, .{});
    };
};

// A setlike, so keys(), values() and the default iterator all yield the entry
// itself and entries() yields it twice.
pub const WGSLLanguageFeatures = struct {
    _pad: bool = false,

    // Chrome 150's list, in its own iteration order.
    const features = [_][]const u8{
        "packed_4x8_integer_dot_product",
        "subgroup_uniformity",
        "immediate_address_space",
        "linear_indexing",
        "subgroup_id",
        "readonly_and_readwrite_storage_textures",
        "unrestricted_pointer_parameters",
        "pointer_composite_access",
        "texture_and_sampler_let",
        "uniform_buffer_standard_layout",
    };

    pub fn getSize(_: *const WGSLLanguageFeatures) u32 {
        return features.len;
    }

    pub fn has(_: *const WGSLLanguageFeatures, name: []const u8) bool {
        for (features) |feature| {
            if (std.mem.eql(u8, feature, name)) {
                return true;
            }
        }
        return false;
    }

    pub fn keys(self: *WGSLLanguageFeatures, exec: *const Execution) !*KeyIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn values(self: *WGSLLanguageFeatures, exec: *const Execution) !*ValueIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn entries(self: *WGSLLanguageFeatures, exec: *const Execution) !*EntryIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn forEach(self: *WGSLLanguageFeatures, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (features) |feature| {
            var caught: js.TryCatch.Caught = undefined;
            cb.tryCall(void, .{ feature, feature, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        features: *WGSLLanguageFeatures,

        pub const Entry = struct { []const u8, []const u8 };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const index = self.index;
            if (index >= WGSLLanguageFeatures.features.len) {
                return null;
            }
            self.index = index + 1;
            const feature = WGSLLanguageFeatures.features[index];
            return .{ feature, feature };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WGSLLanguageFeatures);

        pub const Meta = struct {
            pub const name = "WGSLLanguageFeatures";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const size = bridge.accessor(WGSLLanguageFeatures.getSize, null, .{});
        pub const entries = bridge.function(WGSLLanguageFeatures.entries, .{});
        pub const forEach = bridge.function(WGSLLanguageFeatures.forEach, .{});
        pub const has = bridge.function(WGSLLanguageFeatures.has, .{});
        pub const keys = bridge.function(WGSLLanguageFeatures.keys, .{});
        pub const values = bridge.function(WGSLLanguageFeatures.values, .{});
        pub const symbol_iterator = bridge.iterator(WGSLLanguageFeatures.values, .{});
    };
};
