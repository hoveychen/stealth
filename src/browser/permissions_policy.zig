// Permissions Policy, as it applies to a document that sent no
// Permissions-Policy header -- which is every document this engine commits,
// since the header is not parsed.
//
// With no header, each feature falls back to its default allowlist. Most are
// 'self': a top-level document has them, and so does a frame on the same
// origin as its parent, but a cross-origin <iframe> does not unless the
// element delegates the feature with `allow=`. The rest default to '*' and
// reach every frame.
//
// That split is what a collector running inside a cross-origin iframe sees,
// and Chrome answers it all over the platform: getLayoutMap() rejects with a
// SecurityError, permissions.query() says "denied", featurePolicy.
// allowedFeatures() shrinks from 82 names to the '*' ones, the sensor
// constructors throw. Measured on Chrome 153 with a top document on
// 127.0.0.1 framing localhost (scratch/s115/pp). DataDome's interstitial runs
// in exactly such a frame and scores getLayoutMap() resolving there.

const std = @import("std");

const Frame = @import("Frame.zig");

// The features whose default allowlist is '*': the sixteen Chrome 153 lists
// in a cross-origin frame's allowedFeatures().
const star_default = [_][]const u8{
    "ch-save-data",
    "deferred-fetch-minimal",
    "ch-ua",
    "private-state-token-issuance",
    "interest-cohort",
    "ch-ua-platform",
    "gamepad",
    "aria-notify",
    "ch-ua-high-entropy-values",
    "browsing-topics",
    "ch-ua-mobile",
    "unload",
    "private-state-token-redemption",
    "storage-access",
    "sync-xhr",
    "picture-in-picture",
};

pub fn isStarDefault(feature: []const u8) bool {
    for (star_default) |name| {
        if (std.mem.eql(u8, name, feature)) {
            return true;
        }
    }
    return false;
}

// Whether `frame`'s document may use `feature`. A '*' feature always; a 'self'
// one only if every step from here to the top is same-origin or delegated.
pub fn allows(frame: *const Frame, feature: []const u8) bool {
    if (isStarDefault(feature)) {
        return true;
    }
    return inheritsSelf(frame, feature);
}

// The 'self' half on its own, for the APIs Chrome gates on "top-level or
// same-origin with it" without naming a policy feature.
pub fn inheritsSelf(frame: *const Frame, feature: ?[]const u8) bool {
    var f = frame;
    while (f.parent) |parent| : (f = parent) {
        if (sameOrigin(f, parent)) {
            continue;
        }
        if (feature) |name| {
            if (delegated(f, name)) {
                continue;
            }
        }
        return false;
    }
    return true;
}

// An opaque origin (sandboxed, data:) matches nothing, itself included.
fn sameOrigin(a: *const Frame, b: *const Frame) bool {
    const ao = a.origin orelse return false;
    const bo = b.origin orelse return false;
    return std.mem.eql(u8, ao, bo);
}

// `allow="feature; other 'src'"` on the <iframe> hands the feature down. An
// entry with no allowlist means 'src', which is this frame's own origin; only
// 'none' withholds it. `allowfullscreen` is the legacy spelling of
// allow="fullscreen".
fn delegated(frame: *const Frame, feature: []const u8) bool {
    const iframe = frame.iframe orelse return false;
    const element = iframe.asElement();

    if (std.mem.eql(u8, feature, "fullscreen") and element.getAttributeSafe(.wrap("allowfullscreen")) != null) {
        return true;
    }

    const allow = element.getAttributeSafe(comptime .wrap("allow")) orelse return false;
    var entries = std.mem.splitScalar(u8, allow, ';');
    while (entries.next()) |entry| {
        var tokens = std.mem.tokenizeAny(u8, entry, " \t\n\r\x0c");
        const name = tokens.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, feature)) {
            continue;
        }
        const first = tokens.next() orelse return true;
        if (std.mem.eql(u8, first, "'none'")) {
            return false;
        }
        return true;
    }
    return false;
}

// `allows` for an API reachable from a worker too. A worker's own policy is
// its owner document's; nothing here gates one, so a worker is allowed.
pub fn execAllows(exec: anytype, feature: []const u8) bool {
    return switch (exec.js.global) {
        .frame => |frame| allows(frame, feature),
        .worker => true,
    };
}
