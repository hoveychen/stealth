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

//! Where a CSS animation is right now, expressed as one number: how far
//! through a single iteration the element sits, with the direction already
//! applied. That is all a computed style needs -- the value it reports is the
//! keyframe interval that number falls in, interpolated.
//!
//! This is web-animations-1 §4.5 with the parts a computed style cannot
//! observe left out: no playback rate (a CSS animation's is always 1), no
//! `pending` state, and no timeline other than the document's.

const std = @import("std");

/// `animation-direction`.
pub const Direction = enum {
    normal,
    reverse,
    alternate,
    alternate_reverse,

    pub fn parse(text: []const u8) Direction {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "reverse")) return .reverse;
        if (std.ascii.eqlIgnoreCase(trimmed, "alternate")) return .alternate;
        if (std.ascii.eqlIgnoreCase(trimmed, "alternate-reverse")) return .alternate_reverse;
        return .normal;
    }
};

/// `animation-fill-mode`. Only this decides whether an animation outside its
/// active interval says anything at all about the property.
pub const Fill = enum {
    none,
    forwards,
    backwards,
    both,

    pub fn parse(text: []const u8) Fill {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "forwards")) return .forwards;
        if (std.ascii.eqlIgnoreCase(trimmed, "backwards")) return .backwards;
        if (std.ascii.eqlIgnoreCase(trimmed, "both")) return .both;
        return .none;
    }

    fn fillsBefore(self: Fill) bool {
        return self == .backwards or self == .both;
    }

    fn fillsAfter(self: Fill) bool {
        return self == .forwards or self == .both;
    }
};

/// The `animation-*` longhands that move the number, as seconds and counts.
pub const Timing = struct {
    /// One iteration, in seconds. Zero is legal and collapses the active
    /// interval to a point, which is how `animation-duration: 0s` lands in the
    /// after phase at any elapsed time at all.
    duration: f64 = 0,
    delay: f64 = 0,
    /// `infinite` is stored as it reads: an infinity. The after phase then
    /// never arrives, which is exactly the property the keyword names.
    iterations: f64 = 1,
    direction: Direction = .normal,
    fill: Fill = .none,
    /// `animation-play-state: paused`. A paused animation holds the time it
    /// was paused at, and nothing here ever starts one running, so the held
    /// time is zero: the animation is paused from the moment it is created.
    paused: bool = false,
    /// `animation-timing-function`, applied to each keyframe interval rather
    /// than to the animation as a whole. Kept as text and parsed per read,
    /// since a keyframe may override it with one of its own.
    easing: []const u8 = "ease",
};

/// A `<time>` in seconds. `s` and `ms` are the only two units, and a bare
/// number is not a time at all (`animation-duration: 1` is invalid).
pub fn seconds(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.endsWithIgnoreCase(trimmed, "ms")) {
        const value = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 2]) catch return null;
        return value / 1000;
    }
    if (std.ascii.endsWithIgnoreCase(trimmed, "s")) {
        return std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 1]) catch null;
    }
    return null;
}

/// `animation-iteration-count`: a non-negative number, or the keyword.
pub fn iterationCount(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "infinite")) return std.math.inf(f64);
    const value = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (value < 0) return null;
    return value;
}

/// Which side of its active interval an animation is on.
pub const Phase = enum { before, active, after };

/// Where the animation sits, once. Null means it contributes nothing to the
/// computed value -- an unfilled before or after phase -- and the property
/// then reads whatever the element declares for itself.
pub const Position = struct {
    phase: Phase,
    /// Progress through one iteration, in [0, 1], with `animation-direction`
    /// already applied. The keyframe interval this falls in is the pair of
    /// steps to interpolate between.
    progress: f64,
};

pub fn position(timing: Timing, elapsed: f64) ?Position {
    // A paused animation never advanced, and nothing here can have started it
    // before the page paused it, so its hold time is zero.
    const time = if (timing.paused) 0 else elapsed;
    const local = time - timing.delay;

    const duration = if (timing.duration > 0) timing.duration else 0;
    const active_duration = if (timing.iterations == 0)
        0
    else if (std.math.isInf(timing.iterations))
        std.math.inf(f64)
    else
        duration * timing.iterations;

    if (local < 0) {
        if (!timing.fill.fillsBefore()) return null;
        // The animation has not started, so it shows the start of its first
        // iteration -- which `reverse` and `alternate-reverse` put at the far
        // end of the keyframes.
        return .{ .phase = .before, .progress = directed(timing.direction, 0, 0) };
    }

    if (local >= active_duration) {
        if (!timing.fill.fillsAfter()) return null;
        if (timing.iterations == 0) {
            // Nothing ever ran, so the after phase shows the same value the
            // before phase would: the start of iteration zero.
            return .{ .phase = .after, .progress = directed(timing.direction, 0, 0) };
        }
        // The last iteration the animation reached. A whole iteration count
        // ends ON the boundary, and the frame shown there belongs to the
        // iteration that just finished, not to the one that never started.
        const ceiling = @ceil(timing.iterations);
        const last: f64 = if (ceiling == timing.iterations) ceiling - 1 else @floor(timing.iterations);
        const simple = if (ceiling == timing.iterations) 1 else timing.iterations - @floor(timing.iterations);
        return .{ .phase = .after, .progress = directed(timing.direction, last, simple) };
    }

    // Inside the active interval, and `duration` is non-zero: a zero duration
    // makes `active_duration` zero too, so `local >= active_duration` caught it
    // above and the division below cannot be reached with one.
    const overall = local / duration;
    const iteration = @floor(overall);
    return .{ .phase = .active, .progress = directed(timing.direction, iteration, overall - iteration) };
}

/// `animation-direction` turns a progress into the one the keyframes are read
/// at. `alternate` flips the odd iterations, `alternate-reverse` the even ones.
fn directed(direction: Direction, iteration: f64, progress: f64) f64 {
    const odd = @mod(iteration, 2) >= 1;
    const reverse = switch (direction) {
        .normal => false,
        .reverse => true,
        .alternate => odd,
        .alternate_reverse => !odd,
    };
    return if (reverse) 1 - progress else progress;
}

/// An `<easing-function>` applied to a fraction of a keyframe interval.
///
/// The four `ease*` keywords are the cubic-beziers CSS defines them as, and
/// `step-start` / `step-end` are the two `steps()` shorthands. Anything this
/// does not recognise -- `linear()` with stops, an unparseable
/// `cubic-bezier()` -- is treated as `linear`, which is the identity and so
/// cannot make the value worse than not easing at all.
pub fn ease(easing: []const u8, fraction: f64) f64 {
    const text = std.mem.trim(u8, easing, &std.ascii.whitespace);
    if (fraction <= 0) return 0;
    if (fraction >= 1) return 1;

    if (std.ascii.eqlIgnoreCase(text, "linear")) return fraction;
    if (std.ascii.eqlIgnoreCase(text, "ease")) return bezier(0.25, 0.1, 0.25, 1, fraction);
    if (std.ascii.eqlIgnoreCase(text, "ease-in")) return bezier(0.42, 0, 1, 1, fraction);
    if (std.ascii.eqlIgnoreCase(text, "ease-out")) return bezier(0, 0, 0.58, 1, fraction);
    if (std.ascii.eqlIgnoreCase(text, "ease-in-out")) return bezier(0.42, 0, 0.58, 1, fraction);
    if (std.ascii.eqlIgnoreCase(text, "step-start")) return steps(1, .start, fraction);
    if (std.ascii.eqlIgnoreCase(text, "step-end")) return steps(1, .end, fraction);

    if (functionArgs(text, "cubic-bezier")) |args| {
        var n: [4]f64 = undefined;
        if (scalars(args, &n) != 4) return fraction;
        return bezier(n[0], n[1], n[2], n[3], fraction);
    }
    if (functionArgs(text, "steps")) |args| {
        var it = std.mem.splitScalar(u8, args, ',');
        const count_text = std.mem.trim(u8, it.first(), &std.ascii.whitespace);
        const count = std.fmt.parseFloat(f64, count_text) catch return fraction;
        if (count < 1) return fraction;
        const position_text = if (it.next()) |rest| std.mem.trim(u8, rest, &std.ascii.whitespace) else "end";
        const where: StepPosition = if (std.ascii.eqlIgnoreCase(position_text, "start") or
            std.ascii.eqlIgnoreCase(position_text, "jump-start")) .start else .end;
        return steps(count, where, fraction);
    }
    return fraction;
}

const StepPosition = enum { start, end };

fn steps(count: f64, where: StepPosition, fraction: f64) f64 {
    const index = @floor(fraction * count) + (if (where == .start) @as(f64, 1) else 0);
    return std.math.clamp(index / count, 0, 1);
}

/// The y of the unit cubic bezier (0,0) (x1,y1) (x2,y2) (1,1) at x. Solved for
/// t by Newton first, which converges in a handful of steps for the curves CSS
/// allows, then by bisection for the flat stretches where the derivative is too
/// small to step with.
fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) f64 {
    const curve = struct {
        fn at(a: f64, b: f64, t: f64) f64 {
            // The Bernstein form with the endpoints at 0 and 1 folded in.
            const c = 3 * a;
            const bb = 3 * (b - a) - c;
            const aa = 1 - c - bb;
            return ((aa * t + bb) * t + c) * t;
        }
        fn slope(a: f64, b: f64, t: f64) f64 {
            const c = 3 * a;
            const bb = 3 * (b - a) - c;
            const aa = 1 - c - bb;
            return (3 * aa * t + 2 * bb) * t + c;
        }
    };

    var t = x;
    for (0..8) |_| {
        const err = curve.at(x1, x2, t) - x;
        if (@abs(err) < 1e-7) return curve.at(y1, y2, t);
        const d = curve.slope(x1, x2, t);
        if (@abs(d) < 1e-7) break;
        t -= err / d;
    }

    var low: f64 = 0;
    var high: f64 = 1;
    t = x;
    while (high - low > 1e-7) {
        const at = curve.at(x1, x2, t);
        if (at > x) high = t else low = t;
        t = (low + high) / 2;
    }
    return curve.at(y1, y2, t);
}

/// The inside of `name(...)`, or null when `text` is not a call to `name`.
fn functionArgs(text: []const u8, comptime name: []const u8) ?[]const u8 {
    if (text.len < name.len + 2) return null;
    if (!std.ascii.startsWithIgnoreCase(text, name)) return null;
    if (text[name.len] != '(' or text[text.len - 1] != ')') return null;
    return text[name.len + 1 .. text.len - 1];
}

/// Comma-separated bare numbers into `out`, answering how many were read. A
/// count short of `out.len` means the list did not parse.
fn scalars(args: []const u8, out: []f64) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, args, ',');
    while (it.next()) |raw| {
        if (count == out.len) return count + 1;
        const arg = std.mem.trim(u8, raw, &std.ascii.whitespace);
        out[count] = std.fmt.parseFloat(f64, arg) catch return count;
        count += 1;
    }
    return count;
}

const testing = std.testing;

test "animation_timing: seconds" {
    try testing.expectEqual(@as(?f64, 3), seconds("3s"));
    try testing.expectEqual(@as(?f64, 0.25), seconds("250ms"));
    try testing.expectEqual(@as(?f64, 0), seconds("0s"));
    try testing.expectEqual(@as(?f64, null), seconds("auto"));
    try testing.expectEqual(@as(?f64, null), seconds("3"));
}

test "animation_timing: unfilled phases contribute nothing" {
    const before: Timing = .{ .duration = 3, .delay = 999, .fill = .none };
    try testing.expectEqual(@as(?Position, null), position(before, 0.1));

    const after: Timing = .{ .duration = 0, .delay = 0, .fill = .none };
    try testing.expectEqual(@as(?Position, null), position(after, 0.1));
}

test "animation_timing: filled phases hold an endpoint" {
    const backwards: Timing = .{ .duration = 3, .delay = 999, .fill = .backwards };
    try testing.expectEqual(@as(f64, 0), position(backwards, 0.1).?.progress);

    // `reverse` puts the start of the first iteration at the far end.
    const reversed: Timing = .{ .duration = 3, .delay = 999, .fill = .backwards, .direction = .reverse };
    try testing.expectEqual(@as(f64, 1), position(reversed, 0.1).?.progress);

    const instant: Timing = .{ .duration = 0, .fill = .forwards };
    try testing.expectEqual(@as(f64, 1), position(instant, 0.1).?.progress);
}

test "animation_timing: paused holds the time it was paused at" {
    const paused: Timing = .{ .duration = 3, .paused = true };
    const at = position(paused, 12345).?;
    try testing.expectEqual(Phase.active, at.phase);
    try testing.expectEqual(@as(f64, 0), at.progress);
}

test "animation_timing: alternate flips the odd iterations" {
    const alternate: Timing = .{ .duration = 2, .iterations = std.math.inf(f64), .direction = .alternate };
    try testing.expectApproxEqAbs(@as(f64, 0.25), position(alternate, 0.5).?.progress, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.75), position(alternate, 2.5).?.progress, 1e-9);
}

test "animation_timing: easing" {
    // The two bezier readings are the curves CSS defines the keywords as,
    // solved to 1e-9 by a bisection written separately from the one above --
    // they are the definition rather than a browser measurement, because a
    // browser only shows an eased value part-way through an animation, which
    // is the one reading that cannot be pinned to a number.
    try testing.expectEqual(@as(f64, 0.5), ease("linear", 0.5));
    try testing.expectApproxEqAbs(@as(f64, 0.8024033875), ease("ease", 0.5), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.3153568125), ease("ease-in", 0.5), 1e-6);
    try testing.expectEqual(@as(f64, 0.5), ease("steps(2, end)", 0.75));
    try testing.expectEqual(@as(f64, 1), ease("steps(2, start)", 0.75));
    // Unrecognised easing behaves as `linear` rather than refusing the value.
    try testing.expectEqual(@as(f64, 0.5), ease("wobble(3)", 0.5));
}
