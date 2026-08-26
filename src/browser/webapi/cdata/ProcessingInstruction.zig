// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const CData = @import("../CData.zig");

const ProcessingInstruction = @This();

pub const Proto = CData;

_proto_canary: if (lp.IS_DEBUG) *CData else void = undefined,
_target: []const u8,

pub fn getTarget(self: *const ProcessingInstruction) []const u8 {
    return self._target;
}

fn asCData(self: *ProcessingInstruction) *CData {
    return Factory.protoOf(self);
}

/// The stylesheet an `<?xml-stylesheet?>` instruction pulled in. Nothing here
/// fetches one, and Chrome answers null for a processing instruction that was
/// created from script rather than parsed out of an XML document.
pub fn getSheet(_: *ProcessingInstruction) ?js.Value {
    return null;
}

// A processing instruction's `data` is a run of pseudo-attributes --
// `name="value"`, single or double quoted, whitespace separated -- and Chrome
// exposes the seven Element-shaped methods over it. Reading never rewrites the
// data; the first write re-serialises the whole run with double quotes and
// single spaces (measured on Chrome 151: `href="/s.css"  type='text/css'`
// stays byte for byte until a setAttribute, then becomes
// `type="text/css" href="/s.css" a="b"`).
//
// Blink's own member order is not source order -- that reading came back
// `type,href` for a source that said href first -- because it iterates a
// WTF::HashMap, whose bucket order is not a rule anything should imitate.
// Source order is what this keeps.
const Pseudo = struct {
    name: []const u8,
    value: []const u8,
};

fn parse(self: *ProcessingInstruction, frame: *Frame) ![]Pseudo {
    const data = self.asCData().getData().str();
    var list: std.ArrayList(Pseudo) = .empty;

    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and std.ascii.isWhitespace(data[i])) i += 1;
        const name_start = i;
        while (i < data.len and data[i] != '=' and !std.ascii.isWhitespace(data[i])) i += 1;
        if (i == name_start or i == data.len or data[i] != '=') break;

        const name = data[name_start..i];
        i += 1; // the '='
        if (i == data.len) break;
        const quote = data[i];
        if (quote != '"' and quote != '\'') break;
        i += 1;
        const value_start = i;
        while (i < data.len and data[i] != quote) i += 1;
        if (i == data.len) break;
        try list.append(frame.local_arena, .{ .name = name, .value = data[value_start..i] });
        i += 1; // the closing quote
    }
    return list.items;
}

fn serialize(self: *ProcessingInstruction, items: []const Pseudo, frame: *Frame) !void {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, index| {
        if (index != 0) try out.append(frame.local_arena, ' ');
        try out.appendSlice(frame.local_arena, item.name);
        try out.appendSlice(frame.local_arena, "=\"");
        try out.appendSlice(frame.local_arena, item.value);
        try out.append(frame.local_arena, '"');
    }
    return self.asCData().setData(out.items, frame);
}

pub fn getAttribute(self: *ProcessingInstruction, name: []const u8, frame: *Frame) !?[]const u8 {
    for (try self.parse(frame)) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.value;
    }
    return null;
}

pub fn getAttributeNames(self: *ProcessingInstruction, frame: *Frame) ![]const []const u8 {
    const items = try self.parse(frame);
    const names = try frame.local_arena.alloc([]const u8, items.len);
    for (items, names) |item, *name| {
        name.* = item.name;
    }
    return names;
}

pub fn hasAttribute(self: *ProcessingInstruction, name: []const u8, frame: *Frame) !bool {
    return (try self.getAttribute(name, frame)) != null;
}

pub fn hasAttributes(self: *ProcessingInstruction, frame: *Frame) !bool {
    return (try self.parse(frame)).len != 0;
}

pub fn setAttribute(self: *ProcessingInstruction, name: []const u8, value: []const u8, frame: *Frame) !void {
    const items = try self.parse(frame);
    for (items) |*item| {
        if (std.mem.eql(u8, item.name, name)) {
            item.value = value;
            return self.serialize(items, frame);
        }
    }
    var grown: std.ArrayList(Pseudo) = .empty;
    try grown.appendSlice(frame.local_arena, items);
    try grown.append(frame.local_arena, .{ .name = name, .value = value });
    return self.serialize(grown.items, frame);
}

pub fn removeAttribute(self: *ProcessingInstruction, name: []const u8, frame: *Frame) !void {
    const items = try self.parse(frame);
    var kept: std.ArrayList(Pseudo) = .empty;
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) continue;
        try kept.append(frame.local_arena, item);
    }
    if (kept.items.len == items.len) {
        return;
    }
    return self.serialize(kept.items, frame);
}

/// Chrome's returns undefined here, unlike `Element.toggleAttribute`, which
/// answers whether the attribute is now present (measured on Chrome 151).
pub fn toggleAttribute(self: *ProcessingInstruction, name: []const u8, frame: *Frame) !void {
    if (try self.hasAttribute(name, frame)) {
        return self.removeAttribute(name, frame);
    }
    return self.setAttribute(name, "", frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ProcessingInstruction);

    pub const Meta = struct {
        pub const name = "ProcessingInstruction";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order: the two attributes, then the operations alphabetically.
    pub const target = bridge.accessor(ProcessingInstruction.getTarget, null, .{});
    pub const sheet = bridge.accessor(ProcessingInstruction.getSheet, null, .{});
    pub const getAttribute = bridge.function(ProcessingInstruction.getAttribute, .{ .null_as_undefined = false });
    pub const getAttributeNames = bridge.function(ProcessingInstruction.getAttributeNames, .{});
    pub const hasAttribute = bridge.function(ProcessingInstruction.hasAttribute, .{});
    pub const hasAttributes = bridge.function(ProcessingInstruction.hasAttributes, .{});
    pub const removeAttribute = bridge.function(ProcessingInstruction.removeAttribute, .{});
    pub const setAttribute = bridge.function(ProcessingInstruction.setAttribute, .{});
    pub const toggleAttribute = bridge.function(ProcessingInstruction.toggleAttribute, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: ProcessingInstruction" {
    try testing.htmlRunner("processing_instruction.html", .{});
}
