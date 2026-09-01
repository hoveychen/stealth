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

//! The worklet side of Web Audio, plus the two small readonly interfaces that
//! hang off a context.
//!
//! There is no AudioWorkletGlobalScope here — no second JS realm, no render
//! thread to run a processor on — so `audioWorklet.addModule()` rejects. That
//! is not a stub standing in for something better: it is the same answer Chrome
//! gives when the module will not load (measured: `AbortError: Unable to load a
//! worklet's module.`), and it keeps the rest of the surface self-consistent,
//! because AudioWorkletNode refuses to construct for exactly that reason and
//! says so in Chrome's own words. A resolved addModule() followed by a
//! still-refusing AudioWorkletNode would be the contradiction.
//!
//! The one place Chrome differs is a `data:` URL, which it loads and resolves.
//! Reproducing that would mean claiming a global scope we do not have.
//!
//! `CSS.paintWorklet` is the same interface and does *not* take that line: a
//! paint module is fetched and compiled for real (../css/paint_worklet.zig).
//! Nothing downstream of it contradicts a resolved load, because nothing
//! rasterises at all — there is no paint-worklet equivalent of
//! AudioWorkletNode saying "you never loaded a module".
//!
//! AudioParamMap is likewise shape-only: it is reachable through
//! AudioWorkletNode.parameters and nowhere else, so no script can obtain one.
//!
//! Everything measured on a headed Chrome 150 (win14/win17-chrome.json).

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const DOMException = @import("../DOMException.zig");
const paint_worklet = @import("../css/paint_worklet.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Worklet,
        AudioWorklet,
        AudioWorkletNode,
        AudioParamMap,
        AudioSinkInfo,
        AudioPlaybackStats,
    };
}

/// window.Worklet — the base AudioWorklet inherits from, and the exact type
/// `CSS.paintWorklet` hands out (measured: its constructor is `Worklet` and its
/// chain is `Worklet<Object`, with no subclass in between). Chrome exposes it
/// globally even though nothing can construct one.
pub const Worklet = struct {
    _type: Type,

    pub const Type = union(enum) {
        audio: *AudioWorklet,
        // CSS.paintWorklet. A bare Worklet, so the variant carries nothing;
        // `Local.resolveValue` maps a void payload to this type's own class.
        paint: void,
    };

    /// The two halves of this interface answer differently, and the split is
    /// deliberate. A paint module is fetched and compiled for real
    /// (../css/paint_worklet.zig); an audio one still rejects, because
    /// resolving it would contradict the AudioWorkletNode below, which refuses
    /// to construct in Chrome's own words *because* no module was loaded. See
    /// this file's header.
    pub fn addModule(self: *Worklet, url: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (url == null) return local.rejectPromise(.{ .type_error = "Failed to execute 'addModule' on " ++
            "'Worklet': 1 argument required, but only 0 present." });
        if (self._type == .paint) {
            return paint_worklet.addModule(try url.?.toStringSlice(), exec);
        }
        var resolver = local.createPromiseResolver();
        resolver.reject("Worklet.addModule", DOMException.init("Unable to load a worklet's module.", "AbortError"));
        return resolver.promise();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Worklet);
        pub const Meta = struct {
            pub const name = "Worklet";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const addModule = bridge.function(Worklet.addModule, .{ .arity = 1 });
    };
};

/// BaseAudioContext.audioWorklet. Its prototype adds nothing to Worklet's.
pub const AudioWorklet = struct {
    pub const Proto = Worklet;

    _proto: *Worklet,

    pub fn asWorklet(self: *AudioWorklet) *Worklet {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioWorklet);
        pub const Meta = struct {
            pub const name = "AudioWorklet";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

/// Constructible in Chrome's IDL and refused in practice: without a loaded
/// module there is no AudioWorkletGlobalScope, and Chrome says so. The
/// argument count is still checked first (measured).
pub const AudioWorkletNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,

    pub fn constructor(context: ?js.Value, name: ?js.Value, options: ?js.Value, exec: *Execution) !*AudioWorkletNode {
        const given = [_]?js.Value{ context, name, options };
        const count = idl.present(&given);
        if (count < 2) return idl.argCount("AudioWorkletNode", 2, count, exec);
        return idl.domError(
            "InvalidStateError",
            "Failed to construct 'AudioWorkletNode': AudioWorkletNode cannot be created: AudioWorklet " ++
                "does not have a valid AudioWorkletGlobalScope. Load a script via " ++
                "audioWorklet.addModule() first.",
            exec,
        );
    }

    pub fn asAudioNode(self: *AudioWorkletNode) *AudioNode {
        return self._proto;
    }

    // Unreachable: no instance of this type is ever built. They exist so the
    // prototype carries Chrome's three members.
    pub fn getParameters(_: *AudioWorkletNode) ?*AudioParamMap {
        return null;
    }

    pub fn getPort(_: *AudioWorkletNode) ?*@import("../MessagePort.zig") {
        return null;
    }

    pub fn getOnProcessorError(_: *const AudioWorkletNode) ?js.Function.Global {
        return null;
    }

    pub fn setOnProcessorError(_: *AudioWorkletNode, _: ?js.Function) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioWorkletNode);
        pub const Meta = struct {
            pub const name = "AudioWorkletNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(AudioWorkletNode.constructor, .{ .arity = 2 });
        pub const parameters = bridge.accessor(AudioWorkletNode.getParameters, null, .{});
        pub const port = bridge.accessor(AudioWorkletNode.getPort, null, .{});
        pub const onprocessorerror = bridge.accessor(AudioWorkletNode.getOnProcessorError, AudioWorkletNode.setOnProcessorError, .{});
    };
};

/// AudioWorkletNode.parameters — a readonly map that no script can reach,
/// because no AudioWorkletNode can be built. Shape only.
pub const AudioParamMap = struct {
    _pad: bool = false,

    pub fn getSize(_: *const AudioParamMap) u32 {
        return 0;
    }

    pub fn entries(_: *const AudioParamMap) []const u8 {
        return &.{};
    }

    pub fn forEach(_: *const AudioParamMap, _: ?js.Function) void {}

    pub fn get(_: *const AudioParamMap, _: []const u8) ?*AudioParam {
        return null;
    }

    pub fn has(_: *const AudioParamMap, _: []const u8) bool {
        return false;
    }

    pub fn keys(_: *const AudioParamMap) []const u8 {
        return &.{};
    }

    pub fn values(_: *const AudioParamMap) []const u8 {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioParamMap);
        pub const Meta = struct {
            pub const name = "AudioParamMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const size = bridge.accessor(AudioParamMap.getSize, null, .{});
        pub const entries = bridge.function(AudioParamMap.entries, .{ .arity = 0 });
        pub const forEach = bridge.function(AudioParamMap.forEach, .{ .arity = 1 });
        pub const get = bridge.function(AudioParamMap.get, .{ .arity = 1 });
        pub const has = bridge.function(AudioParamMap.has, .{ .arity = 1 });
        pub const keys = bridge.function(AudioParamMap.keys, .{ .arity = 0 });
        pub const values = bridge.function(AudioParamMap.values, .{ .arity = 0 });
    };
};

/// AudioContext.sinkId when the context was built with a sink *type* rather
/// than a device id: `new AudioContext({sinkId: {type: 'none'}})` (measured).
pub const AudioSinkInfo = struct {
    _sink_type: SinkType,

    pub const SinkType = enum {
        none,
    };

    pub fn getType(self: *const AudioSinkInfo) []const u8 {
        return @tagName(self._sink_type);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioSinkInfo);
        pub const Meta = struct {
            pub const name = "AudioSinkInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const @"type" = bridge.accessor(AudioSinkInfo.getType, null, .{});
    };
};

/// AudioContext.playbackStats. Every counter is zero, which is what Chrome
/// reports for a context that never rendered a frame (measured — all six read
/// back 0 on a fresh suspended context).
pub const AudioPlaybackStats = struct {
    _pad: bool = false,

    fn zero(_: *const AudioPlaybackStats) f64 {
        return 0;
    }

    fn zeroCount(_: *const AudioPlaybackStats) u32 {
        return 0;
    }

    pub fn resetLatency(_: *AudioPlaybackStats) void {}

    // The presence and arity of toJSON are measured; its *contents* are not —
    // nothing was rendered, so Chrome's own answer here is all zeros either
    // way, and this mirrors the six attributes.
    pub fn toJSON(_: *const AudioPlaybackStats) Json {
        return .{};
    }

    pub const Json = struct {
        underrunDuration: f64 = 0,
        underrunEvents: u32 = 0,
        totalDuration: f64 = 0,
        averageLatency: f64 = 0,
        minimumLatency: f64 = 0,
        maximumLatency: f64 = 0,
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioPlaybackStats);
        pub const Meta = struct {
            pub const name = "AudioPlaybackStats";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const underrunDuration = bridge.accessor(AudioPlaybackStats.zero, null, .{});
        pub const underrunEvents = bridge.accessor(AudioPlaybackStats.zeroCount, null, .{});
        pub const totalDuration = bridge.accessor(AudioPlaybackStats.zero, null, .{});
        pub const averageLatency = bridge.accessor(AudioPlaybackStats.zero, null, .{});
        pub const minimumLatency = bridge.accessor(AudioPlaybackStats.zero, null, .{});
        pub const maximumLatency = bridge.accessor(AudioPlaybackStats.zero, null, .{});
        pub const resetLatency = bridge.function(AudioPlaybackStats.resetLatency, .{ .arity = 0 });
        pub const toJSON = bridge.function(AudioPlaybackStats.toJSON, .{ .arity = 0 });
    };
};
