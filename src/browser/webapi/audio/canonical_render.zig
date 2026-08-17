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

//! The one offline render this engine answers with real samples.
//!
//! There is no DSP here and there will not be: G10 established that the audio
//! fingerprint cannot be computed at all (the oscillator's wavetable comes from
//! 36 inverse FFTs backed by a different library per platform, and the
//! compressor calls the platform's libm per sample). What G21 does instead is
//! replay a render that was *recorded* off real Chrome on each target platform
//! — chrome_audio.zig — for the exact graph that every fingerprintjs clone
//! builds, and only for that graph.
//!
//! Two things follow from replaying rather than computing, and both are the
//! reason this file is as fussy as it is.
//!
//! The match has to be exact. A detector that probes the *shape* of the graph
//! rather than hashing one render is not hypothetical — it is the obvious next
//! move against exactly this trick — and a stored buffer handed back for a
//! graph that would render something else is a far louder tell than silence.
//! Every deviation measured so far lands somewhere completely different:
//! threshold -50 → -40 moves the tail sum from 124.043 to 141.405, and 44100 →
//! 48000 Hz moves it to 122.603. So a mismatch falls back to silence, which is
//! what the rest of this engine renders.
//!
//! But "exact" is about the signal reaching the destination, not about the
//! graph being nothing but these two nodes. A gain node hanging off the side
//! does not change what Chrome renders, so refusing to replay for one would be
//! a divergence invented here rather than a fidelity gained. Hence the match is
//! on the destination's *incoming* edges: exactly one node feeds it, that node
//! is the canonical compressor, exactly one node feeds the compressor, and that
//! node is the canonical oscillator. Anything else in the context is ignored,
//! the way Chrome ignores it.
//!
//! Known gaps, all of them silence where Chrome renders something:
//!
//!   * past frame 5000 there is nothing recorded, so a longer render replays
//!     what there is and stops. 5000 frames at 44100 is what fingerprintjs
//!     asks for, and a longer render is frame-for-frame identical over the
//!     frames they share (measured), so a prefix is right as far as it goes.
//!   * a stereo destination. Only the mono render was recorded; whether Chrome
//!     up-mixes it to identical channels was never measured, and guessing is
//!     not worth the tell if the guess is wrong.
//!   * a source that was stopped. `stop()` records that it happened but not
//!     when, so a stop past the end of the render — which changes nothing in
//!     Chrome — cannot be told from one that truncates.
//!   * a graph that modulates an AudioParam. Those edges are not recorded at
//!     all, only counted (BaseAudioContext._param_edges).

const std = @import("std");
const builtin = @import("builtin");

const js = @import("../../js/js.zig");

const nodes = @import("nodes.zig");
const AudioNode = @import("AudioNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const chrome_audio = @import("chrome_audio.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

/// The recorded render for the platform this engine claims to be, or null when
/// there is none for it. Tied to the build target for now; G21's P3 moves the
/// claim off the build host, and this is the seam it moves through — the
/// user-agent, navigator.platform and the audio buffer have to name the same
/// platform or the disagreement is itself the fingerprint.
fn platform() ?chrome_audio.Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => null,
    };
}

/// Fills `buffer` with the recorded render if `context`'s graph is the
/// canonical one, and leaves it silent otherwise. Called from
/// startRendering(), which is where Chrome captures the graph too.
pub fn apply(context: *BaseAudioContext, buffer: *AudioBuffer, exec: *const Execution) void {
    const recorded = platform() orelse return;
    if (buffer._channels.len != 1) return;
    if (!matches(context)) return;

    const samples = chrome_audio.samples(recorded);
    const channel = buffer._channels[0].local(exec.js.local.?).slice();
    const count = @min(channel.len, samples.len);
    @memcpy(channel[0..count], samples[0..count]);
}

fn matches(context: *BaseAudioContext) bool {
    if (context._sample_rate != chrome_audio.sample_rate) return false;
    if (context._param_edges != 0) return false;

    const destination = context._destination orelse return false;
    if (destination._proto._channel_count != 1) return false;

    const compressor = switch ((soleSource(context, destination._proto) orelse return false)._type) {
        .dynamics_compressor => |compressor| compressor,
        else => return false,
    };
    // fingerprintjs's five settings, assigned through `param.value = x` so the
    // comparison is against exactly the doubles it wrote.
    if (compressor._threshold._value != -50) return false;
    if (compressor._knee._value != 40) return false;
    if (compressor._ratio._value != 12) return false;
    if (compressor._attack._value != 0) return false;
    if (compressor._release._value != 0.25) return false;

    const source = switch ((soleSource(context, compressor._proto) orelse return false)._type) {
        .scheduled_source => |scheduled| scheduled,
        else => return false,
    };
    if (!source._started or source._stopped or source._start_when != 0) return false;

    const oscillator = switch (source._type) {
        .oscillator => |oscillator| oscillator,
        else => return false,
    };
    if (oscillator._type != .triangle) return false;
    if (oscillator._frequency._value != 10000) return false;
    if (oscillator._detune._value != 0) return false;

    return true;
}

/// The single node with an edge into `target`, or null when nothing feeds it or
/// more than one thing does. A node connected to the same target twice still
/// counts once, because a repeated connect() is a no-op in Chrome.
fn soleSource(context: *BaseAudioContext, target: *AudioNode) ?*AudioNode {
    var found: ?*AudioNode = null;
    for (context._nodes.items) |node| {
        if (node == target) continue;
        for (node._outputs.items) |output| {
            if (output != target) continue;
            if (found != null and found != node) return null;
            found = node;
            break;
        }
    }
    return found;
}
