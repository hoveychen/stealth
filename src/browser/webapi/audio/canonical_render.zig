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

//! The offline renders this engine answers with real samples.
//!
//! There is no DSP here and there will not be: G10 established that the audio
//! fingerprint cannot be computed at all (the oscillator's wavetable comes from
//! 36 inverse FFTs backed by a different library per platform, and the
//! compressor calls the platform's libm per sample). What G21 does instead is
//! replay renders that were *recorded* off real Chrome on each target platform
//! — chrome_audio.zig — for exactly the graphs that were recorded, and for no
//! others.
//!
//! There are two. fingerprintjs's is the one every clone of that library
//! builds. The Cloudflare Turnstile widget's is the same shape with three of the
//! numbers moved — a 9 998.123456 Hz tone, a −52 dB threshold and a 0.0001 s
//! attack — which is why it used to fall through to silence here while the
//! oracle answered with 1 000 real floats. It was read off the live station by
//! tools/fingerprint/audio-graph-trace.mjs, and the render Chrome gives that
//! graph reproduces the vector the station recorded to a maximum difference of
//! zero.
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
//! on the destination's *incoming* edges: every one of them reaches a recorded
//! graph's compressor — directly or through nodes that pass their input on
//! unchanged — exactly one node feeds that compressor, and that node is the
//! graph's oscillator. Anything else in the context is ignored, the way Chrome
//! ignores it.
//!
//! More than one edge is allowed because iphey builds exactly that: the
//! compressor reaches the destination directly *and* through an analyser, and
//! Chrome sums the two into precisely twice the single-path buffer. Requiring a
//! sole source handed that page silence where Chrome renders a tone, which is
//! the loudest tell this file can produce.
//!
//! The numbers are read through `AudioParam.renderValue()` rather than off
//! `param.value`, because a page can put them on the automation timeline
//! instead of assigning them and the getter does not move until a render has
//! run — Chrome's does not either. Kasada does exactly that with the
//! oscillator's frequency on x-hyatt (`setValueAtTime`, seq 482 of
//! tools/fingerprint/results/prop-reads-hyatt.json), and Chrome renders the
//! same buffer both ways, so reading `value` handed that station silence.
//!
//! Anything on the timeline past its start says the parameter is not a
//! constant and no recording applies — including an event scheduled after the
//! render is over, which sounds harmless and is not: Chrome renders
//! 124.04346760431508 for the canonical graph with one event a second past the
//! end of a 0.1134 s render, against 124.04347624466754 with none. A timeline
//! that exists is walked.
//!
//! Known gaps, all of them silence where Chrome renders something:
//!
//!   * past frame 5000 there is nothing recorded, so a longer render replays
//!     what there is and stops. 5000 frames at 44100 is what fingerprintjs
//!     asks for and the widget asks for 1000, and a longer render is
//!     frame-for-frame identical over the frames they share (checked on every
//!     run of the generator, for both graphs), so a prefix is right as far as
//!     it goes.
//!   * a stereo destination. Only the mono render was recorded; whether Chrome
//!     up-mixes it to identical channels was never measured, and guessing is
//!     not worth the tell if the guess is wrong.
//!   * a source that was stopped. `stop()` records that it happened but not
//!     when, so a stop past the end of the render — which changes nothing in
//!     Chrome — cannot be told from one that truncates.
//!   * a graph that modulates an AudioParam. Those edges are not recorded at
//!     all, only counted (BaseAudioContext._param_edges).
//!   * three or more edges into the destination. Two sum to exactly twice the
//!     recording; three do not come out at exactly three times it in Chrome
//!     (372.13042371820484 against 372.1304244073908), so the sum stops being a
//!     multiple of what is stored here.
//!   * a gain node the page moved off 1. Chrome scales the signal by it —
//!     exactly half the canonical tail at 0.5 — and scaling a recording is
//!     arithmetic this file has no measurement to back.

const std = @import("std");

const js = @import("../../js/js.zig");
const claimed_platform = @import("../../../claimed_platform.zig");

const nodes = @import("nodes.zig");
const AudioNode = @import("AudioNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const chrome_audio = @import("chrome_audio.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

/// The recorded render belonging to the platform this engine claims to be —
/// not the one it was built on. A buffer recorded on macOS handed to a page
/// that was just told `navigator.platform` is `Linux x86_64` is a contradiction
/// costing one render to find, so both come from claimed_platform.
///
/// Exhaustive on purpose: a new claim with no recorded render of its own fails
/// to compile here rather than silently replaying someone else's machine.
fn platform() chrome_audio.Platform {
    return switch (claimed_platform.claimed) {
        .macos => .macos,
        .linux => .linux,
    };
}

/// Fills `buffer` with the recorded render if `context`'s graph is one of the
/// recorded ones, and leaves it silent otherwise. Called from startRendering(),
/// which is where Chrome captures the graph too.
pub fn apply(context: *BaseAudioContext, buffer: *AudioBuffer, exec: *const Execution) void {
    if (buffer._channels.len != 1) return;
    const match = which(context) orelse return;

    const samples = chrome_audio.samples(match.graph, platform());
    const channel = buffer._channels[0].local(exec.js.local.?).slice();
    const count = @min(channel.len, samples.len);
    @memcpy(channel[0..count], samples[0..count]);
    if (match.paths == 2) {
        // Two edges carrying one signal into the destination sum there, and
        // Chrome's sum of a value with itself is exactly twice it: iphey's
        // graph renders 248.0869496049272 against the single path's
        // 124.0434748024636, to the last bit. Three paths do *not* come out at
        // exactly three times (372.13042371820484 against 372.1304244073908),
        // so `which` refuses anything past two rather than guess at the
        // ordering Chrome mixes them in.
        for (channel[0..count]) |*sample| sample.* *= 2;
    }
}

/// A recorded graph, and how many edges carry it into the destination.
const Match = struct {
    graph: chrome_audio.Graph,
    paths: u8,
};

/// Which recorded graph `context` builds, or null when it builds anything else.
///
/// The structure is shared by every graph with a recording -- a started
/// triangle oscillator into a compressor into a mono destination -- and only
/// the six numbers differ, so the shape is checked once and the numbers are
/// checked against each candidate in turn.
fn which(context: *BaseAudioContext) ?Match {
    if (context._sample_rate != chrome_audio.sample_rate) return null;
    if (context._param_edges != 0) return null;

    const destination = context._destination orelse return null;
    if (destination._proto._channel_count != 1) return null;

    // The destination is allowed more than one incoming edge, because the graph
    // iphey builds has two: the compressor reaches it directly *and* through an
    // analyser. An analyser passes its input through unchanged, so both edges
    // carry the same signal and the destination sums them. Refusing that shape
    // is what handed iphey silence where Chrome renders a tone, and silence off
    // a graph Chrome renders is the loudest tell this file has.
    var edge_storage: [2]*AudioNode = undefined;
    const edges = context.sources(destination._proto, &edge_storage) orelse return null;
    if (edges.len == 0) return null;

    var compressor_node: ?*AudioNode = null;
    for (edges) |edge| {
        const reached = passThrough(context, edge) orelse return null;
        if (compressor_node != null and compressor_node != reached) return null;
        compressor_node = reached;
    }

    const compressor = switch ((compressor_node orelse return null)._type) {
        .dynamics_compressor => |compressor| compressor,
        else => return null,
    };

    const source = switch ((context.soleSource(compressor._proto) orelse return null)._type) {
        .scheduled_source => |scheduled| scheduled,
        else => return null,
    };
    if (!source._started or source._stopped or source._start_when != 0) return null;

    const oscillator = switch (source._type) {
        .oscillator => |oscillator| oscillator,
        else => return null,
    };
    if (oscillator._type != .triangle) return null;
    const detune = oscillator._detune.renderValue() orelse return null;
    if (detune != 0) return null;

    // What the render would hold each parameter at, which is what the page
    // wrote for the start of the render whether it assigned it or scheduled it
    // there. Half of one graph and half of another is neither, and falls
    // through to silence with everything else.
    const frequency = oscillator._frequency.renderValue() orelse return null;
    const threshold = compressor._threshold.renderValue() orelse return null;
    const knee = compressor._knee.renderValue() orelse return null;
    const ratio = compressor._ratio.renderValue() orelse return null;
    const attack = compressor._attack.renderValue() orelse return null;
    const release = compressor._release.renderValue() orelse return null;

    for (std.enums.values(chrome_audio.Graph)) |graph| {
        const want = chrome_audio.settings(graph);
        if (frequency != want.frequency) continue;
        if (threshold != want.threshold) continue;
        if (knee != want.knee) continue;
        if (ratio != want.ratio) continue;
        if (attack != want.attack) continue;
        if (release != want.release) continue;
        return .{ .graph = graph, .paths = @intCast(edges.len) };
    }
    return null;
}

/// Walks back from `node` through the nodes that hand their input on unchanged,
/// and returns the first node that does something. Null when the chain does not
/// end somewhere -- an analyser fed by two things carries a mix, which is not
/// the recorded signal.
///
/// An analyser is transparent unconditionally -- it has nothing to set. A gain
/// node is transparent only while its gain renders as 1, which is its default:
/// Chrome renders the single-path sum through one (`gainDefault` and `gainOne`
/// in tools/fingerprint/probes/expr-b153-gain.js) and exactly half of it at 0.5,
/// so a gain the page moved is a graph with no recording rather than one to
/// replay through. `renderValue` answers null for a gain on the automation
/// timeline, which lands in the same place.
fn passThrough(context: *BaseAudioContext, node: *AudioNode) ?*AudioNode {
    var current = node;
    // Chrome renders a transparent chain of any depth as the plain signal; two
    // is as deep as anything measured goes, and a cycle cannot outlast this.
    for (0..8) |_| {
        switch (current._type) {
            .analyser => {},
            .gain => |gain| if ((gain._gain.renderValue() orelse return null) != 1) return current,
            else => return current,
        }
        current = context.soleSource(current) orelse return null;
    }
    return null;
}
