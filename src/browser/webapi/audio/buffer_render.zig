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

//! The one offline render this engine computes rather than replays.
//!
//! canonical_render.zig hands back recordings because its graphs cannot be
//! computed at all: an oscillator's wavetable comes from 36 inverse FFTs backed
//! by a different library per platform, and a compressor calls the platform's
//! libm per sample (G10). An AudioBufferSource has neither. Its buffer is bytes
//! the page itself wrote, and with no resampling asked for, Chrome hands those
//! same bytes to the destination -- measured, 1 000 frames in and the same
//! 1 000 float32s out, maximum difference zero. So this render is arithmetic on
//! the page's own memory, needs no recording, and is identical on every
//! platform.
//!
//! It is worth having because the Cloudflare Turnstile widget builds three
//! offline contexts per visit: two are the compressor graph canonical_render
//! answers, and the third is exactly this -- createBuffer, fill it,
//! createBufferSource, straight into the destination. Rendering silence for it
//! is a difference from Chrome that costs nothing to remove.
//!
//! Everything below was measured on a headed Chrome 151, case for case, by
//! tools/fingerprint/probes/expr-buffer-source-oracle.js. That probe prints the
//! same strings the `audio_buffer_source_render` test in
//! src/browser/tests/audio.html compares against, so every rule here can be
//! re-checked against Chrome in one command.
//!
//! What Chrome does, and therefore what this does:
//!
//!   * the buffer is read from `offset`, one frame per rendered frame, into the
//!     destination starting at `when`; `duration` and `stop()` each cut it
//!     short, and running off the end of the buffer ends it.
//!   * looping wraps the read at `loopEnd` back to `loopStart`, with the window
//!     clamped to the buffer and a default `loopEnd` of 0 meaning the whole of
//!     it. A backwards window is no loop at all, and an `offset` at or past
//!     `loopEnd` is pulled back to `loopStart`.
//!   * channels are matched one to one, a mono buffer is duplicated into a
//!     stereo destination, and a stereo one is averaged down into a mono
//!     destination.
//!
//! Known gaps, all of them silence where Chrome renders something. The rule is
//! canonical_render's: a render that is nearly right is a louder tell than one
//! that is plainly absent, so anything this cannot reproduce exactly is left
//! alone rather than approximated.
//!
//!   * any resampling -- a buffer whose sample rate differs from the context's,
//!     a `playbackRate` other than 1, or a nonzero `detune`. Chrome interpolates
//!     with a kernel this does not have.
//!   * a schedule that lands between two frames. `when` is the sharp one:
//!     Chrome interpolates the whole buffer onto the offset grid rather than
//!     rounding, so half a frame late is not the same signal one frame late.
//!     `offset`, `duration`, `stop()` and the loop points do round in Chrome,
//!     but 2.5 and 3.5 frames both round *up* there and one measurement cannot
//!     tell round-half-up from ceil, so they are refused too rather than
//!     guessed.
//!   * more than one source reaching the destination. Chrome sums them; summing
//!     here would be right for two buffer sources and wrong the moment one of
//!     them is anything else.
//!   * channel counts other than the three measured above.
//!   * a modulated AudioParam. Those edges are not recorded, only counted
//!     (BaseAudioContext._param_edges), so a modulated playbackRate would read
//!     as the unity one it was left at.

const std = @import("std");

const js = @import("../../js/js.zig");

const nodes = @import("nodes.zig");
const AudioNode = @import("AudioNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

/// Fills `buffer` with what an AudioBufferSource feeding `context`'s
/// destination renders, and leaves it alone otherwise. Called from
/// startRendering(), which is where Chrome captures the graph too.
///
/// Nothing here writes zeros: the buffer arrives silent from
/// AudioBuffer.create, so bailing out at any point below leaves exactly the
/// silence this engine renders for every graph it does not answer.
pub fn apply(context: *BaseAudioContext, buffer: *AudioBuffer, exec: *const Execution) void {
    const plan = Plan.of(context) orelse return;
    const local = exec.js.local.?;

    for (buffer._channels, 0..) |channel, index| {
        const out = channel.local(local).slice();
        // Which of the buffer's channels this output channel is built from:
        // its own under .direct, and channel 0 (with channel 1) otherwise.
        const left = plan.source._channels[if (plan.mix == .direct) index else 0].local(local).slice();
        const right = if (plan.mix == .average) plan.source._channels[1].local(local).slice() else left;

        const last = @min(plan.end, out.len);
        var frame = plan.start;
        while (frame < last) : (frame += 1) {
            const read = plan.read(frame - plan.start) orelse break;
            out[@intCast(frame)] = switch (plan.mix) {
                .direct, .duplicate => left[read],
                // Chrome's stereo-to-mono down-mix, in the same single
                // precision it does it in (measured: 1 and 10 come back 5.5).
                .average => (left[read] + right[read]) * 0.5,
            };
        }
    }
}

/// How the buffer's channels reach the destination's. Only the three Chrome was
/// measured doing are here; every other pair is refused, which is what keeps a
/// guessed mixing rule out of a render a detector could hash.
const Mix = enum {
    /// Equal counts: channel i of the buffer is channel i of the render.
    direct,
    /// One channel into two, written to both.
    duplicate,
    /// Two channels into one, averaged.
    average,

    fn of(from: usize, to: usize) ?Mix {
        if (from == to) return .direct;
        if (from == 1 and to == 2) return .duplicate;
        if (from == 2 and to == 1) return .average;
        return null;
    }
};

/// The half-open window a looping source wraps within. `end` is the first
/// frame it does not play before going back to `start`.
const LoopWindow = struct { start: u64, end: u64 };

/// A render reduced to the four numbers that decide it: which frames of the
/// destination the source occupies, where in the buffer it reads from, and how
/// it wraps. Built only when every rule in the header holds.
const Plan = struct {
    source: *AudioBuffer,
    mix: Mix,

    /// The half-open window of *rendered* frames the source writes to.
    start: u64,
    end: u64,

    /// Where in the buffer the first of those frames reads from.
    offset: u64,

    /// The loop window, or null when the source does not repeat.
    loop: ?LoopWindow,

    /// Which frame of the buffer the source's `nth` frame reads, or null once
    /// it has run off the end and there is nothing left to play.
    fn read(self: Plan, nth: u64) ?usize {
        var at = self.offset + nth;
        if (self.loop) |loop| {
            if (at >= loop.end) {
                // The wrap is modulo the window rather than a subtraction: a
                // buffer shorter than the render goes round it many times.
                at = loop.start + (at - loop.end) % (loop.end - loop.start);
            }
        }
        if (at >= self.source._length) return null;
        return @intCast(at);
    }

    fn of(context: *BaseAudioContext) ?Plan {
        // A modulated parameter is not recorded anywhere, so playbackRate could
        // be anything by the time Chrome reads it.
        if (context._param_edges != 0) return null;

        const destination = context._destination orelse return null;
        const source = sourceOf(context, destination._proto) orelse return null;
        const scheduled = source._proto;
        if (!scheduled._started) return null;

        const buffer = source._buffer orelse return null;
        // Any of these three asks Chrome to resample, which is the one thing
        // this cannot reproduce.
        if (buffer._sample_rate != context._sample_rate) return null;
        // renderValue, not `value`: a parameter that was scheduled onto the
        // timeline rather than assigned reads back unmoved before the render
        // has run, in Chrome too, but it is what the render sees.
        const playback_rate = source._playback_rate.renderValue() orelse return null;
        if (playback_rate != 1) return null;
        const detune = source._detune.renderValue() orelse return null;
        if (detune != 0) return null;

        const rate = context._sample_rate;
        const start = frames(scheduled._start_when, rate) orelse return null;
        const offset = frames(source._start_offset, rate) orelse return null;

        // The render runs to the length of the destination buffer unless
        // stop() cuts it shorter; a stop at or before the start plays nothing.
        var end: u64 = std.math.maxInt(u64);
        if (scheduled._stopped) {
            end = frames(scheduled._stop_when, rate) orelse return null;
        }
        if (source._start_duration) |duration| {
            const span = frames(duration, rate) orelse return null;
            end = @min(end, start +| span);
        }
        if (end <= start) return null;

        const loop: ?LoopWindow = if (source._loop) blk: {
            const loop_start = @min(frames(source._loop_start, rate) orelse return null, buffer._length);
            // A loopEnd left at its default of 0 means the whole buffer, and
            // one past the end is clamped to it (both measured).
            const raw_end = frames(source._loop_end, rate) orelse return null;
            const loop_end = if (raw_end == 0) buffer._length else @min(raw_end, buffer._length);
            // A backwards or empty window is no loop at all in Chrome: the
            // source plays straight through and stops.
            if (loop_start >= loop_end) break :blk null;
            break :blk .{ .start = loop_start, .end = loop_end };
        } else null;

        return .{
            .source = buffer,
            .mix = Mix.of(buffer._channels.len, destination._proto._channel_count) orelse return null,
            .start = start,
            .end = end,
            // An offset at or past the end of the loop window never plays the
            // tail of the buffer -- Chrome pulls it back to the window's start.
            .offset = if (loop) |l| (if (offset >= l.end) l.start else offset) else offset,
            .loop = loop,
        };
    }
};

/// The node feeding `target`, walking through gain nodes left at unity along
/// the way: Chrome renders the same samples through one as without it
/// (measured), so refusing to answer for a page that wraps its source in a
/// gain node would be a divergence invented here.
fn sourceOf(context: *BaseAudioContext, target: *AudioNode) ?*nodes.AudioBufferSourceNode {
    var at = target;
    // Bounded by the node count: connect() will happily build a cycle, and a
    // walk backwards through one would otherwise not terminate.
    for (0..context._nodes.items.len) |_| {
        const node = context.soleSource(at) orelse return null;
        switch (node._type) {
            .gain => |gain| {
                const unity = gain._gain.renderValue() orelse return null;
                if (unity != 1) return null;
                at = node;
            },
            .scheduled_source => |scheduled| return switch (scheduled._type) {
                .audio_buffer_source => |source| source,
                else => null,
            },
            else => return null,
        }
    }
    return null;
}

/// `seconds` as a whole number of frames, or null when it is not one.
///
/// Refusing a fraction is the point rather than a shortcut: a `when` half a
/// frame late makes Chrome interpolate the entire buffer onto the offset grid,
/// so rounding it here would answer a plausible signal that is not the one the
/// page would have got.
fn frames(seconds: f64, rate: f64) ?u64 {
    const exact = seconds * rate;
    // Catches NaN as well, which is what a `start(undefined)` converts to.
    if (!(exact >= 0) or exact > std.math.maxInt(u32)) return null;
    if (exact != @floor(exact)) return null;
    return @intFromFloat(exact);
}
