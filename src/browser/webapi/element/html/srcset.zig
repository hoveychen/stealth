// Which of an `<img srcset>`'s candidates a browser actually asks for.
//
// A page that offers three sizes and gets asked for the `src` fallback has
// told the server it is not a browser: measured with
// tools/fingerprint/wire-census.mjs, Chrome asked for `srcset-2x.png` and
// `sizes-800.png` where this engine asked for the two fallbacks -- four rows
// of one census, and unlike a property reading it is a difference the origin
// sees in its own log.
//
// Nothing here renders, so "which candidate" is not a question about pixels;
// it is only ever a question about which URL goes on the wire. That is why
// this is a string function with no layout in it.
//
// ⚠️ The reference arm has to run at THIS engine's devicePixelRatio, not at
// the host's. `Window.getDevicePixelRatio` answers 2, so `2x` is the right
// candidate and a Chrome left at scale 1 will answer `1x` -- the harness
// disagreeing with itself, not a bug. Same trap as the layout readings
// (`chrome-arm-needs-persona-dpr`).
const std = @import("std");

// One `url descriptor` pair out of a srcset attribute.
pub const Candidate = struct {
    url: []const u8,
    // Device pixels of image width the candidate offers. A `2x` descriptor on
    // its own says nothing about width, so the two forms are kept apart rather
    // than converted into each other.
    density: ?f64 = null,
    width: ?f64 = null,
};

/// The candidate Chrome would fetch, or null when the attribute names none --
/// in which case the caller falls back to `src`, which is what the attribute
/// is there for.
///
/// `sizes` is the raw attribute (empty when absent, which the spec reads as
/// `100vw`). `viewport_width` and `dpr` are CSS pixels and the device pixel
/// ratio.
pub fn select(srcset: []const u8, sizes: []const u8, viewport_width: f64, dpr: f64) ?[]const u8 {
    var widths: bool = false;
    var it = candidates(srcset);
    while (it.next()) |c| {
        if (c.width != null) widths = true;
    }

    if (widths) {
        const wanted = sourceSize(sizes, viewport_width) * dpr;
        return smallestAtLeast(srcset, wanted, .width);
    }
    return smallestAtLeast(srcset, dpr, .density);
}

const Descriptor = enum { width, density };

// The smallest candidate that is still big enough, and the largest one when
// none is: a browser never downgrades below what it needs if it can help it,
// and never refuses to show an image because every candidate is too small.
fn smallestAtLeast(srcset: []const u8, wanted: f64, comptime kind: Descriptor) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_value: f64 = 0;
    var largest: ?[]const u8 = null;
    var largest_value: f64 = 0;

    var it = candidates(srcset);
    while (it.next()) |c| {
        const value = switch (kind) {
            .width => c.width orelse continue,
            // A candidate with no descriptor at all is `1x`.
            .density => c.density orelse 1,
        };
        if (value >= wanted and (best == null or value < best_value)) {
            best = c.url;
            best_value = value;
        }
        if (largest == null or value > largest_value) {
            largest = c.url;
            largest_value = value;
        }
    }
    return best orelse largest;
}

/// The `sizes` attribute's default source size, in CSS pixels.
///
/// Only the default entry is read -- the last one, the one with no media
/// condition. Honouring the conditions would mean evaluating media queries
/// against a viewport nothing here lays out against, and the default is what
/// every entry collapses to at the widths this engine claims.
fn sourceSize(sizes: []const u8, viewport_width: f64) f64 {
    if (sizes.len == 0) return viewport_width;

    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, sizes, ',');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, &std.ascii.whitespace);
        if (trimmed.len != 0) last = trimmed;
    }

    // `(max-width: 600px) 480px` -- the length is what follows the condition.
    var length = last;
    if (std.mem.lastIndexOfScalar(u8, last, ')')) |close| {
        length = std.mem.trim(u8, last[close + 1 ..], &std.ascii.whitespace);
    }
    return cssLength(length, viewport_width) orelse viewport_width;
}

fn cssLength(text: []const u8, viewport_width: f64) ?f64 {
    if (std.mem.endsWith(u8, text, "px")) {
        return std.fmt.parseFloat(f64, text[0 .. text.len - 2]) catch null;
    }
    if (std.mem.endsWith(u8, text, "vw")) {
        const percent = std.fmt.parseFloat(f64, text[0 .. text.len - 2]) catch return null;
        return viewport_width * percent / 100;
    }
    return null;
}

/// Walks a srcset attribute.
///
/// Splitting on commas is not quite the spec's tokenizer -- a URL may carry a
/// comma as long as it is not followed by whitespace -- but the spec also
/// forbids a URL that starts or ends with one, and every srcset seen in the
/// wild separates its candidates exactly this way.
pub fn candidates(srcset: []const u8) Iterator {
    return .{ .rest = srcset };
}

pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) ?Candidate {
        while (self.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const entry = std.mem.trim(u8, self.rest[0..end], &std.ascii.whitespace);
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";
            if (entry.len == 0) continue;

            const split = std.mem.indexOfAny(u8, entry, " \t\r\n") orelse entry.len;
            const url = entry[0..split];
            if (url.len == 0) continue;

            const descriptor = std.mem.trim(u8, entry[split..], &std.ascii.whitespace);
            if (descriptor.len == 0) return .{ .url = url };
            const number = descriptor[0 .. descriptor.len - 1];
            const value = std.fmt.parseFloat(f64, number) catch return .{ .url = url };
            return switch (descriptor[descriptor.len - 1]) {
                'w', 'W' => .{ .url = url, .width = value },
                'x', 'X' => .{ .url = url, .density = value },
                // `h` is a descriptor no browser implements.
                else => .{ .url = url },
            };
        }
        return null;
    }
};

const testing = @import("../../../../testing.zig");

test "srcset: density descriptors pick by devicePixelRatio" {
    const set = "/a-1x.png 1x, /a-2x.png 2x, /a-3x.png 3x";
    try testing.expectString("/a-1x.png", select(set, "", 1920, 1).?);
    try testing.expectString("/a-2x.png", select(set, "", 1920, 2).?);
    try testing.expectString("/a-3x.png", select(set, "", 1920, 2.5).?);
    // Past every candidate: the largest, not nothing.
    try testing.expectString("/a-3x.png", select(set, "", 1920, 4).?);
}

test "srcset: a bare candidate is 1x" {
    try testing.expectString("/plain.png", select("/plain.png", "", 1920, 1).?);
    try testing.expectString("/big.png", select("/plain.png, /big.png 2x", "", 1920, 2).?);
}

test "srcset: width descriptors resolve sizes against the viewport" {
    const set = "/w-400.png 400w, /w-800.png 800w, /w-1600.png 1600w";
    // 100 CSS px at dpr 2 wants 200 device px: the 400w is the smallest that
    // covers it.
    try testing.expectString("/w-400.png", select(set, "100px", 1920, 2).?);
    // 100vw of a 1920 viewport at dpr 2 wants 3840: nothing covers it, so the
    // largest wins.
    try testing.expectString("/w-1600.png", select(set, "100vw", 1920, 2).?);
    // Absent sizes reads as 100vw.
    try testing.expectString("/w-1600.png", select(set, "", 1920, 2).?);
    try testing.expectString("/w-800.png", select(set, "50vw", 800, 2).?);
}

test "srcset: only the default entry of sizes is read" {
    const set = "/w-400.png 400w, /w-800.png 800w";
    try testing.expectString("/w-400.png", select(set, "(max-width: 600px) 1000px, 100px", 1920, 2).?);
}

test "srcset: an empty attribute names nothing" {
    try testing.expectEqual(null, select("", "", 1920, 2));
    try testing.expectEqual(null, select("  ,  ", "", 1920, 2));
}
