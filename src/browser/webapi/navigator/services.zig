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
const MediaMetadata = @import("../media/MediaMetadata.zig").MediaMetadata;
const chrome_sdp = @import("../webrtc/chrome_sdp.zig");
const StorageManager = @import("../StorageManager.zig");
const idb = @import("../storage/idb/idb.zig");
const webgpu_adapter = @import("../webgpu/adapter.zig");
const cache_storage = @import("../storage/cache_storage.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Scheduling,
        UserActivation,
        ProtectedAudience,
        NavigatorLogin,
        MediaCapabilities,
        MediaSession,
        GPU,
        WGSLLanguageFeatures,
        WGSLLanguageFeatures.KeyIterator,
        WGSLLanguageFeatures.ValueIterator,
        WGSLLanguageFeatures.EntryIterator,
        Keyboard,
        KeyboardLayoutMap,
        KeyboardLayoutMap.KeyIterator,
        KeyboardLayoutMap.ValueIterator,
        KeyboardLayoutMap.EntryIterator,
        LockManager,
        Lock,
        Ink,
        DelegatedInkTrailPresenter,
        StorageBucketManager,
        StorageBucket,
        DeprecatedStorageQuota,
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
        // Alphabetical: a dictionary's members are read in that order.
        audio: ?Track = null,
        type: []const u8 = "",
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
    _metadata: ?*MediaMetadata = null,

    const PlaybackState = enum { none, paused, playing };

    // Null until a page sets one, and it keeps the very object it was handed:
    // `navigator.mediaSession.metadata === m` is true afterwards (measured).
    pub fn getMetadata(self: *const MediaSession) ?*MediaMetadata {
        return self._metadata;
    }

    pub fn setMetadata(self: *MediaSession, value_: ?js.Value, exec: *const js.Execution) !void {
        const value = value_ orelse {
            self._metadata = null;
            return;
        };
        if (value.isNullOrUndefined()) {
            self._metadata = null;
            return;
        }
        self._metadata = value.toZig(*MediaMetadata) catch {
            const isolate = exec.js.isolate;
            _ = isolate.throwException(isolate.createTypeError(
                "Failed to set the 'metadata' property on 'MediaSession': " ++
                    "Failed to convert value to 'MediaMetadata'.",
            ));
            return error.JsException;
        };
    }

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

pub const GPU = struct {
    // Allocated on first read rather than embedded: the JS identity map is
    // keyed by Zig address alone, and a struct's first-in-memory field shares
    // its owner's address — an embedded instance would come back branded as its
    // owner.
    _features: ?*WGSLLanguageFeatures = null,

    pub fn getWgslLanguageFeatures(self: *GPU, exec: *Execution) !*WGSLLanguageFeatures {
        if (self._features) |features| {
            return features;
        }
        const created = try exec._factory.create(WGSLLanguageFeatures{});
        self._features = created;
        return created;
    }

    // Fixed in every Chromium build on this platform; measured 'bgra8unorm'.
    pub fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "bgra8unorm";
    }

    // This used to resolve null, on the grounds that implementing GPUAdapter
    // would mean inventing a GPU's limits — a far louder lie than having none.
    // That reasoning no longer applies: the reference Chrome 150 on this platform
    // has a working adapter, so its features, its 36 limits and its adapterInfo
    // were all measured rather than invented (win37-chrome.json, win38-chrome.json).
    // A Chrome that sends a Chrome user-agent and then has no adapter at all is
    // the contradiction now, not the other way round.
    pub fn requestAdapter(_: *const GPU, options: ?js.Value, exec: *const Execution) !js.Promise {
        return webgpu_adapter.GPUAdapter.request(options, exec);
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
            var caught: js.TryCatch.Caught = .{};
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
        pub const symbol_iterator = bridge.iterator(WGSLLanguageFeatures.values, .{ .js_name = "values" });
    };
};

pub const Keyboard = struct {
    _pad: bool = false,

    // Resolves the host's physical keyboard layout, the same 48 entries the
    // reference Chrome hands back. Every desktop Chrome resolves a populated
    // map, so an empty one — which this used to answer — is a shape no browser
    // has; a shared layout is at worst a common machine.
    pub fn getLayoutMap(_: *const Keyboard, exec: *const Execution) !js.Promise {
        const map = try exec._factory.create(KeyboardLayoutMap{});
        return exec.js.local.?.resolvePromise(map);
    }

    // Nothing to capture keys from, and Chrome resolves with nothing too
    // (measured).
    pub fn lock(_: *const Keyboard, _: ?[]const []const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn unlock(_: *const Keyboard) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Keyboard);

        pub const Meta = struct {
            pub const name = "Keyboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const getLayoutMap = bridge.function(Keyboard.getLayoutMap, .{});
        pub const lock = bridge.function(Keyboard.lock, .{});
        pub const unlock = bridge.function(Keyboard.unlock, .{});
    };
};

pub const KeyboardLayoutMap = struct {
    _pad: bool = false,

    // Every writing-system key of the reference host's layout: the
    // KeyboardEvent.code and the character that key produces. The order is
    // Chrome's own — not alphabetical, but byte-identical across three runs —
    // and it is load-bearing, because collectors join the pairs before hashing
    // them.
    const layout = [_][2][]const u8{
        .{ "KeyK", "k" },
        .{ "KeyG", "g" },
        .{ "Digit2", "2" },
        .{ "Digit0", "0" },
        .{ "KeyV", "v" },
        .{ "KeyA", "a" },
        .{ "Backquote", "`" },
        .{ "KeyL", "l" },
        .{ "IntlBackslash", "§" },
        .{ "Quote", "'" },
        .{ "KeyW", "w" },
        .{ "Digit8", "8" },
        .{ "KeyM", "m" },
        .{ "KeyH", "h" },
        .{ "Period", "." },
        .{ "Digit7", "7" },
        .{ "Digit1", "1" },
        .{ "KeyP", "p" },
        .{ "KeyD", "d" },
        .{ "KeyF", "f" },
        .{ "KeyO", "o" },
        .{ "KeyQ", "q" },
        .{ "KeyC", "c" },
        .{ "KeyN", "n" },
        .{ "BracketLeft", "[" },
        .{ "KeyZ", "z" },
        .{ "KeyY", "y" },
        .{ "Digit3", "3" },
        .{ "Digit6", "6" },
        .{ "Digit5", "5" },
        .{ "KeyX", "x" },
        .{ "Slash", "/" },
        .{ "Backslash", "\\" },
        .{ "Comma", "," },
        .{ "Minus", "-" },
        .{ "Digit4", "4" },
        .{ "KeyB", "b" },
        .{ "KeyT", "t" },
        .{ "Digit9", "9" },
        .{ "KeyS", "s" },
        .{ "KeyI", "i" },
        .{ "KeyU", "u" },
        .{ "Equal", "=" },
        .{ "KeyJ", "j" },
        .{ "Semicolon", ";" },
        .{ "KeyR", "r" },
        .{ "BracketRight", "]" },
        .{ "KeyE", "e" },
    };

    pub fn getSize(_: *const KeyboardLayoutMap) u32 {
        return layout.len;
    }

    pub fn get(_: *const KeyboardLayoutMap, code: []const u8) ?[]const u8 {
        const index = indexOf(code) orelse return null;
        return layout[index][1];
    }

    pub fn has(_: *const KeyboardLayoutMap, code: []const u8) bool {
        return indexOf(code) != null;
    }

    fn indexOf(code: []const u8) ?usize {
        for (layout, 0..) |entry, i| {
            if (std.mem.eql(u8, entry[0], code)) {
                return i;
            }
        }
        return null;
    }

    pub fn keys(self: *KeyboardLayoutMap, exec: *const Execution) !*KeyIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn values(self: *KeyboardLayoutMap, exec: *const Execution) !*ValueIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn entries(self: *KeyboardLayoutMap, exec: *const Execution) !*EntryIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn forEach(self: *KeyboardLayoutMap, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (layout) |entry| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ entry[1], entry[0], self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        map: *KeyboardLayoutMap,

        pub const Entry = struct { []const u8, []const u8 };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const index = self.index;
            if (index >= KeyboardLayoutMap.layout.len) {
                return null;
            }
            self.index = index + 1;

            return .{ KeyboardLayoutMap.layout[index][0], KeyboardLayoutMap.layout[index][1] };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(KeyboardLayoutMap);

        pub const Meta = struct {
            pub const name = "KeyboardLayoutMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            // Deliberately not `empty_with_no_proto`: that path stores no
            // tagged opaque, so every method receives one shared static
            // instance rather than the map the caller holds, and the third
            // argument forEach hands its callback would not be the map itself
            // the way Chrome's is.
        };

        pub const size = bridge.accessor(KeyboardLayoutMap.getSize, null, .{});
        pub const entries = bridge.function(KeyboardLayoutMap.entries, .{});
        pub const forEach = bridge.function(KeyboardLayoutMap.forEach, .{});
        pub const get = bridge.function(KeyboardLayoutMap.get, .{ .null_as_undefined = true });
        pub const has = bridge.function(KeyboardLayoutMap.has, .{});
        pub const keys = bridge.function(KeyboardLayoutMap.keys, .{});
        pub const values = bridge.function(KeyboardLayoutMap.values, .{});
        pub const symbol_iterator = bridge.iterator(KeyboardLayoutMap.entries, .{});
    };
};

pub const LockManager = struct {
    _pad: bool = false,

    const Snapshot = struct {
        held: []const []const u8 = &.{},
        pending: []const []const u8 = &.{},
    };

    // Nothing else holds a web lock in this engine, which is also what Chrome
    // reported on a page that had taken none.
    pub fn query(_: *const LockManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Snapshot{});
    }

    // The lock is granted immediately — there is no other agent to contend with
    // — and the promise settles with whatever the callback returned, as
    // Chrome's does. The `request(name, options, callback)` overload is not
    // accepted: only the two-argument form is, which is the shape Chrome
    // reports a length of 2 for.
    pub fn request(_: *const LockManager, name: []const u8, callback: js.Function, exec: *const Execution) !js.Promise {
        const held = try exec._factory.create(Lock{ ._name = try exec.arena.dupe(u8, name) });
        const result = try callback.call(js.Value, .{held});
        return exec.js.local.?.resolvePromise(result);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LockManager);

        pub const Meta = struct {
            pub const name = "LockManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const query = bridge.function(LockManager.query, .{});
        pub const request = bridge.function(LockManager.request, .{});
    };
};

pub const Lock = struct {
    _name: []const u8,

    pub fn getName(self: *const Lock) []const u8 {
        return self._name;
    }

    // 'exclusive' is the default mode and the one the reference Chrome handed
    // back for a request that didn't ask for anything else.
    pub fn getMode(_: *const Lock) []const u8 {
        return "exclusive";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Lock);

        pub const Meta = struct {
            pub const name = "Lock";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Lock.getName, null, .{});
        pub const mode = bridge.accessor(Lock.getMode, null, .{});
    };
};

pub const Ink = struct {
    _pad: bool = false,

    pub fn requestPresenter(_: *const Ink, _: ?js.Object, exec: *const Execution) !js.Promise {
        const presenter = try exec._factory.create(DelegatedInkTrailPresenter{});
        return exec.js.local.?.resolvePromise(presenter);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Ink);

        pub const Meta = struct {
            pub const name = "Ink";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const requestPresenter = bridge.function(Ink.requestPresenter, .{});
    };
};

pub const DelegatedInkTrailPresenter = struct {
    _pad: bool = false,

    // null when the presenter was requested without a presentation element,
    // which is what the reference Chrome reported.
    pub fn getPresentationArea(_: *const DelegatedInkTrailPresenter) ?bool {
        return null;
    }

    // There is no ink trail to move; Chrome's own answer is undefined.
    pub fn updateInkTrailStartPoint(_: *const DelegatedInkTrailPresenter, _: js.Value, _: js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DelegatedInkTrailPresenter);

        pub const Meta = struct {
            pub const name = "DelegatedInkTrailPresenter";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const presentationArea = bridge.accessor(DelegatedInkTrailPresenter.getPresentationArea, null, .{});
        pub const updateInkTrailStartPoint = bridge.function(DelegatedInkTrailPresenter.updateInkTrailStartPoint, .{});
    };
};

pub const StorageBucketManager = struct {
    _pad: bool = false,

    pub fn open(_: *const StorageBucketManager, name: []const u8, _: ?js.Object, exec: *const Execution) !js.Promise {
        const bucket = try exec._factory.create(StorageBucket{ ._name = try exec.arena.dupe(u8, name) });
        return exec.js.local.?.resolvePromise(bucket);
    }

    // No bucket was ever persisted, so there are no keys and nothing to delete.
    pub fn keys(_: *const StorageBucketManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
    }

    pub fn delete(_: *const StorageBucketManager, _: []const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageBucketManager);

        pub const Meta = struct {
            pub const name = "StorageBucketManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const delete = bridge.function(StorageBucketManager.delete, .{});
        pub const keys = bridge.function(StorageBucketManager.keys, .{});
        pub const open = bridge.function(StorageBucketManager.open, .{});
    };
};

pub const StorageBucket = struct {
    _name: []const u8,
    // Chrome gives each bucket its own CacheStorage, distinct from
    // window.caches and stable across reads (measured).
    _caches: cache_storage.CacheStorage = .init,

    // A bucket is a slice of the same origin pool, so it quotes the same size
    // the other three surfaces do. Inferred rather than measured: the reference
    // run covered navigator.storage and the two webkit pools, not this one —
    // but a bucket answering a different pool size than navigator.storage would
    // be the engine disagreeing with itself, which is the tell being closed
    // here. Key order is Chrome's for this object (measured).
    const Estimate = struct {
        usage: f64 = 0,
        quota: f64 = StorageManager.quota_bytes,
    };

    pub fn getName(self: *const StorageBucket) []const u8 {
        return self._name;
    }

    // The bucket shares the page's IDB factory rather than getting one of its
    // own — a separate database namespace would be a difference a page could
    // observe, and we have none to give it.
    // The realm's own factory, whichever realm that is: both globals answer
    // `getIndexedDB`, and reaching past the union to `.frame` was the only
    // thing keeping the bucket family out of a worker.
    pub fn getIndexedDB(_: *const StorageBucket, exec: *Execution) !*idb.IDBFactory {
        return switch (exec.js.global) {
            .frame => |frame| frame.window.getIndexedDB(exec),
            .worker => |worker| worker.getIndexedDB(exec),
        };
    }

    pub fn getCaches(self: *StorageBucket) *cache_storage.CacheStorage {
        return &self._caches;
    }

    pub fn estimate(_: *const StorageBucket, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Estimate{});
    }

    pub fn expires(_: *const StorageBucket, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }

    // The bucket file system is not implemented; Chrome rejects getDirectory
    // with a DOMException when it can't hand one out.
    pub fn getDirectory(_: *const StorageBucket, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    }

    pub fn persisted(_: *const StorageBucket, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }

    pub fn setExpires(_: *const StorageBucket, _: f64, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn persist(_: *const StorageBucket, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageBucket);

        pub const Meta = struct {
            pub const name = "StorageBucket";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "setExpires";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(StorageBucket.getName, null, .{});
        pub const indexedDB = bridge.accessor(StorageBucket.getIndexedDB, null, .{});
        pub const caches = bridge.accessor(StorageBucket.getCaches, null, .{});
        pub const estimate = bridge.function(StorageBucket.estimate, .{});
        pub const expires = bridge.function(StorageBucket.expires, .{});
        pub const getDirectory = bridge.function(StorageBucket.getDirectory, .{});
        pub const persisted = bridge.function(StorageBucket.persisted, .{});
        pub const setExpires = bridge.function(StorageBucket.setExpires, .{});
        pub const persist = bridge.function(StorageBucket.persist, .{ .exposed = .window });
    };
};

// navigator.webkitTemporaryStorage / webkitPersistentStorage. Chrome brands both
// [object DeprecatedStorageQuota] but exposes no such global and puts no
// `constructor` on the prototype: the interface is [LegacyNoInterfaceObject]
// (measured — globalThis.DeprecatedStorageQuota is undefined there).
pub const DeprecatedStorageQuota = struct {
    // The pool size, with nothing stored — see StorageManager.quota_bytes for
    // where the figure comes from and why it matters. An f64 rather than a u64:
    // quotas past 2^32 come back from a u64 as a BigInt, and Chrome reports a
    // plain Number.
    _quota: f64,

    pub fn queryUsageAndQuota(
        self: *const DeprecatedStorageQuota,
        callback: js.Function,
        _: ?js.Function,
    ) !void {
        _ = try callback.call(void, .{ @as(f64, 0), self._quota });
    }

    // Chrome granted exactly what was asked for (measured: requestQuota(1024)
    // called back with 1024).
    pub fn requestQuota(
        _: *const DeprecatedStorageQuota,
        bytes: f64,
        callback: ?js.Function,
        _: ?js.Function,
    ) !void {
        if (callback) |cb| {
            _ = try cb.call(void, .{bytes});
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DeprecatedStorageQuota);

        pub const Meta = struct {
            pub const name = "DeprecatedStorageQuota";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = true;
        };

        pub const queryUsageAndQuota = bridge.function(DeprecatedStorageQuota.queryUsageAndQuota, .{});
        pub const requestQuota = bridge.function(DeprecatedStorageQuota.requestQuota, .{});
    };
};
