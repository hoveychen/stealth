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

//! The three nodes that bridge Web Audio and MediaStream.
//!
//! They are the only nodes whose first constructor parameter is an
//! `AudioContext` rather than a `BaseAudioContext`, and Chrome's refusal says so
//! by name — an OfflineAudioContext is rejected with "parameter 1 is not of type
//! 'AudioContext'" (measured), which is also why the three matching factories
//! live on AudioContext.prototype and are absent from an offline one.
//!
//! No audio moves through any of them: the destination's stream carries a track
//! that never delivers a frame, and the two sources read from an element or a
//! stream that never produces one. Everything a script can read without a frame
//! -- the channel counts, the identity of the element or stream handed in, and
//! each refusal -- came off a headed Chrome 150 over http://localhost
//! (win18-chrome.json).

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const AudioNode = @import("AudioNode.zig");
const AudioContext = @import("AudioContext.zig");
const Media = @import("../element/html/Media.zig");
const streams = @import("../media/streams.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        MediaStreamAudioDestinationNode,
        MediaElementAudioSourceNode,
        MediaStreamAudioSourceNode,
    };
}

// The three AudioNodeOptions members, applied straight to the fields. Same
// reasoning as nodes.zig's copy: the setters police a *later* assignment.
fn applyNodeOptions(base: *AudioNode, dict: ?js.Object) !void {
    if (try idl.optionalU32(dict, "channelCount")) |count| {
        base._channel_count = count;
    }
    if (dict) |obj| {
        const mode = try obj.get("channelCountMode");
        if (!mode.isUndefined()) {
            idl.assignEnum(AudioNode.ChannelCountMode, &base._channel_count_mode, try mode.toStringSlice());
        }
        const interpretation = try obj.get("channelInterpretation");
        if (!interpretation.isUndefined()) {
            idl.assignEnum(AudioNode.ChannelInterpretation, &base._channel_interpretation, try interpretation.toStringSlice());
        }
    }
}

// ---------------------------------------------------------------------------
// MediaStreamAudioDestinationNode
// ---------------------------------------------------------------------------

/// A second destination, alongside `context.destination`: it takes input,
/// produces no output, and exposes the whole thing as a MediaStream. This is the
/// only way a page reaches a live MediaStreamTrack without a permission.
pub const MediaStreamAudioDestinationNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,

    // The same stream object every time (measured: d.stream === d.stream), and a
    // different one per node (measured: two nodes' streams differ).
    _stream: *streams.MediaStream,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*MediaStreamAudioDestinationNode {
        const ctx = try idl.realtimeContext("MediaStreamAudioDestinationNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("MediaStreamAudioDestinationNode", "AudioNodeOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);
        return node;
    }

    pub fn create(ctx: *AudioContext, exec: *Execution) !*MediaStreamAudioDestinationNode {
        const base = ctx.asBaseAudioContext();

        const stream = try streams.MediaStream.create(exec);
        const track = try streams.MediaStreamTrack.create(
            "MediaStreamAudioDestinationNode",
            2,
            base._sample_rate,
            exec,
        );
        try stream._tracks.append(exec.arena, track);

        const node = try exec._factory.audioNode(MediaStreamAudioDestinationNode{
            ._proto = undefined,
            ._stream = stream,
        });
        node._proto._context = base;
        // Like context.destination: input only, and an explicit channel count.
        node._proto._number_of_outputs = 0;
        node._proto._channel_count_mode = .explicit;
        return node;
    }

    pub fn asAudioNode(self: *MediaStreamAudioDestinationNode) *AudioNode {
        return self._proto;
    }

    pub fn getStream(self: *const MediaStreamAudioDestinationNode) *streams.MediaStream {
        return self._stream;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamAudioDestinationNode);

        pub const Meta = struct {
            pub const name = "MediaStreamAudioDestinationNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaStreamAudioDestinationNode.constructor, .{ .arity = 1 });
        pub const stream = bridge.accessor(MediaStreamAudioDestinationNode.getStream, null, .{});
    };
};

// ---------------------------------------------------------------------------
// MediaElementAudioSourceNode
// ---------------------------------------------------------------------------

/// Routes an `<audio>` or `<video>` element's output into the graph. An element
/// can only ever back one of these, and Chrome refuses the second attempt by
/// name rather than handing back the first node.
pub const MediaElementAudioSourceNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _element: *Media,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*MediaElementAudioSourceNode {
        const where = "Failed to construct 'MediaElementAudioSourceNode'";
        const ctx = try idl.realtimeContext("MediaElementAudioSourceNode", 2, &.{ context, options }, exec);
        const dict = try idl.options("MediaElementAudioSourceNode", "MediaElementAudioSourceOptions", options, exec);
        const value = try idl.requiredMember(
            "MediaElementAudioSourceNode",
            "MediaElementAudioSourceOptions",
            "mediaElement",
            dict,
            exec,
        );
        // A <div> fails here the same way a number does: Chrome reports the
        // conversion, not the tag (measured).
        const element = value.toZig(*Media) catch return idl.typeError(
            where ++ ": Failed to read the 'mediaElement' property from " ++
                "'MediaElementAudioSourceOptions': Failed to convert value to 'HTMLMediaElement'.",
            exec,
        );

        const node = try create(where, ctx, element, exec);
        try applyNodeOptions(node._proto, dict);
        return node;
    }

    // Shared with AudioContext.createMediaElementSource, which blames itself.
    // The "already connected" refusal is measured on the factory path; the
    // constructor is assumed to claim the element the same way, because
    // otherwise one element could back two nodes.
    pub fn create(
        comptime where: []const u8,
        ctx: *AudioContext,
        element: *Media,
        exec: *Execution,
    ) !*MediaElementAudioSourceNode {
        if (element._audio_source_connected) {
            return idl.domError(
                "InvalidStateError",
                where ++ ": HTMLMediaElement already connected previously to a different " ++
                    "MediaElementSourceNode.",
                exec,
            );
        }
        element._audio_source_connected = true;

        const node = try exec._factory.audioNode(MediaElementAudioSourceNode{
            ._proto = undefined,
            ._element = element,
        });
        node._proto._context = ctx.asBaseAudioContext();
        node._proto._number_of_inputs = 0;
        return node;
    }

    pub fn asAudioNode(self: *MediaElementAudioSourceNode) *AudioNode {
        return self._proto;
    }

    pub fn getMediaElement(self: *const MediaElementAudioSourceNode) *Media {
        return self._element;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaElementAudioSourceNode);

        pub const Meta = struct {
            pub const name = "MediaElementAudioSourceNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaElementAudioSourceNode.constructor, .{ .arity = 2 });
        pub const mediaElement = bridge.accessor(MediaElementAudioSourceNode.getMediaElement, null, .{});
    };
};

// ---------------------------------------------------------------------------
// MediaStreamAudioSourceNode
// ---------------------------------------------------------------------------

/// Routes the first audio track of a MediaStream into the graph. A stream with
/// no audio track is refused -- and note the message has no full stop, unlike
/// every other refusal in this family (measured, twice).
pub const MediaStreamAudioSourceNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _stream: *streams.MediaStream,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*MediaStreamAudioSourceNode {
        const where = "Failed to construct 'MediaStreamAudioSourceNode'";
        const ctx = try idl.realtimeContext("MediaStreamAudioSourceNode", 2, &.{ context, options }, exec);
        const dict = try idl.options("MediaStreamAudioSourceNode", "MediaStreamAudioSourceOptions", options, exec);
        const value = try idl.requiredMember(
            "MediaStreamAudioSourceNode",
            "MediaStreamAudioSourceOptions",
            "mediaStream",
            dict,
            exec,
        );
        const stream = value.toZig(*streams.MediaStream) catch return idl.typeError(
            where ++ ": Failed to read the 'mediaStream' property from " ++
                "'MediaStreamAudioSourceOptions': Failed to convert value to 'MediaStream'.",
            exec,
        );

        const node = try create(where, ctx, stream, exec);
        try applyNodeOptions(node._proto, dict);
        return node;
    }

    // Shared with AudioContext.createMediaStreamSource. The empty-stream
    // refusal is measured on the factory path; the constructor is assumed to
    // make the same check, since it has the same nothing-to-read problem.
    pub fn create(
        comptime where: []const u8,
        ctx: *AudioContext,
        stream: *streams.MediaStream,
        exec: *Execution,
    ) !*MediaStreamAudioSourceNode {
        var has_audio = false;
        for (stream._tracks.items) |track| {
            if (track._kind == .audio) {
                has_audio = true;
                break;
            }
        }
        if (!has_audio) {
            return idl.domError("InvalidStateError", where ++ ": MediaStream has no audio track", exec);
        }

        const node = try exec._factory.audioNode(MediaStreamAudioSourceNode{
            ._proto = undefined,
            ._stream = stream,
        });
        node._proto._context = ctx.asBaseAudioContext();
        node._proto._number_of_inputs = 0;
        return node;
    }

    pub fn asAudioNode(self: *MediaStreamAudioSourceNode) *AudioNode {
        return self._proto;
    }

    pub fn getMediaStream(self: *const MediaStreamAudioSourceNode) *streams.MediaStream {
        return self._stream;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamAudioSourceNode);

        pub const Meta = struct {
            pub const name = "MediaStreamAudioSourceNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaStreamAudioSourceNode.constructor, .{ .arity = 2 });
        pub const mediaStream = bridge.accessor(MediaStreamAudioSourceNode.getMediaStream, null, .{});
    };
};
