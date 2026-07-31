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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// BaseAudioContext.destination — the end of the graph. Adds exactly one member
// to AudioNode (maxChannelCount), which is the whole of Chrome's
// AudioDestinationNode.prototype besides `constructor` (measured).
//
// Its node values are the ones deviceandbrowserinfo copies into its audio
// fingerprint as `dest-*`, so they mirror a stereo Chrome output verbatim:
// maxChannelCount 2, numberOfInputs 1, numberOfOutputs 0, channelCount 2,
// channelCountMode "explicit", channelInterpretation "speakers".

const js = @import("../../js/js.zig");
const AudioNode = @import("AudioNode.zig");

const AudioDestinationNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,

pub fn asAudioNode(self: *AudioDestinationNode) *AudioNode {
    return self._proto;
}

pub fn getMaxChannelCount(_: *const AudioDestinationNode) u32 {
    return 2;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDestinationNode);

    pub const Meta = struct {
        pub const name = "AudioDestinationNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const maxChannelCount = bridge.accessor(AudioDestinationNode.getMaxChannelCount, null, .{});
};
