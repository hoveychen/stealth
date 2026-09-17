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

// The on-device summarization model's front door. One of the five names
// DataDome's device-check program asked for and did not get; see
// BarcodeDetector.zig for the set and where it came from.
//
// Measured on a headed Chrome 152 (probe scratch/s34/shape.js plus the
// behaviour readings in the plan's P2 notes):
//
//   * Summarizer.length is 0 and `new Summarizer()` is a TypeError reading
//     "Failed to construct 'Summarizer': Illegal constructor" -- the interface
//     has no constructor operation, so an instance only ever comes from
//     create().
//   * The interface object carries two statics, availability and create.
//   * availability() resolves with "downloadable" on a machine that has not
//     fetched the model -- which is every machine this engine runs on.
//   * The prototype carries, in this order, sharedContext, type, format,
//     length, expectedInputLanguages, expectedContextLanguages, outputLanguage,
//     inputQuota, destroy, measureInputUsage, summarize and summarizeStreaming.
//   * [SecureContext]: absent from an insecure origin, so the name is in
//     secure_context.gated_interfaces.
//
// No instance is reachable: create() rejects, because availability is
// "downloadable" and nothing here has a user activation to spend on starting
// the download. That rejection follows the Writing Assistance APIs spec rather
// than a Chrome reading -- it was not measured -- but no instance means the
// prototype's members are only ever seen as descriptors, never invoked.

const js = @import("../js/js.zig");
const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const Summarizer = @This();

// Padding to avoid a zero-size struct, which causes identity_map pointer
// collisions. Nothing constructs one of these.
_pad: bool = false,

pub fn constructor(exec: *const Execution) !*Summarizer {
    return exec.js.fail(error.TypeError, "Failed to construct 'Summarizer': Illegal constructor");
}

pub fn availability(exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const u8, "downloadable"));
}

pub fn create(_: ?js.Value, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("Summarizer.create", DOMException.init(
        "Requires a user gesture when availability is \"downloadable\".",
        "NotAllowedError",
    ));
    return resolver.promise();
}

// The prototype's members. Unreachable -- create() never yields an instance --
// so these exist to carry the descriptors the interface's shape is read from.
pub fn destroy(_: *Summarizer) void {}

pub fn getExpectedContextLanguages(_: *const Summarizer) ?[]const []const u8 {
    return null;
}

pub fn getExpectedInputLanguages(_: *const Summarizer) ?[]const []const u8 {
    return null;
}

pub fn getFormat(_: *const Summarizer) []const u8 {
    return "markdown";
}

pub fn getInputQuota(_: *const Summarizer) f64 {
    return 0;
}

pub fn getLength(_: *const Summarizer) []const u8 {
    return "short";
}

pub fn measureInputUsage(_: *Summarizer, _: []const u8, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as(f64, 0));
}

pub fn getOutputLanguage(_: *const Summarizer) ?[]const u8 {
    return null;
}

pub fn getSharedContext(_: *const Summarizer) []const u8 {
    return "";
}

pub fn summarize(_: *Summarizer, _: []const u8, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const u8, ""));
}

pub fn summarizeStreaming(_: *Summarizer, _: []const u8, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const u8, ""));
}

pub fn getType(_: *const Summarizer) []const u8 {
    return "key-points";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Summarizer);

    pub const Meta = struct {
        pub const name = "Summarizer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Summarizer.constructor, .{});
    pub const availability = bridge.function(Summarizer.availability, .{ .static = true });
    pub const create = bridge.function(Summarizer.create, .{ .static = true, .arity = 0 });

    // Chrome's prototype order (measured), which is not alphabetical: the eight
    // attributes first, in IDL declaration order, then the four operations.
    pub const sharedContext = bridge.accessor(Summarizer.getSharedContext, null, .{});
    pub const @"type" = bridge.accessor(Summarizer.getType, null, .{});
    pub const format = bridge.accessor(Summarizer.getFormat, null, .{});
    pub const length = bridge.accessor(Summarizer.getLength, null, .{});
    pub const expectedInputLanguages = bridge.accessor(Summarizer.getExpectedInputLanguages, null, .{});
    pub const expectedContextLanguages = bridge.accessor(Summarizer.getExpectedContextLanguages, null, .{});
    pub const outputLanguage = bridge.accessor(Summarizer.getOutputLanguage, null, .{});
    pub const inputQuota = bridge.accessor(Summarizer.getInputQuota, null, .{});
    pub const destroy = bridge.function(Summarizer.destroy, .{});
    pub const measureInputUsage = bridge.function(Summarizer.measureInputUsage, .{});
    pub const summarize = bridge.function(Summarizer.summarize, .{});
    pub const summarizeStreaming = bridge.function(Summarizer.summarizeStreaming, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Summarizer" {
    try testing.htmlRunner("summarizer.html", .{});
}
