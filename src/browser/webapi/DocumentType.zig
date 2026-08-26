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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");

const DocumentType = @This();

pub const Proto = Node;

_proto: *Node,
_name: []const u8,
_public_id: []const u8,
_system_id: []const u8,

pub fn init(qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, frame: *Frame) !*DocumentType {
    const name = try frame.dupeString(qualified_name);
    // Firefox converts null to the string "null", not empty string
    const pub_id = if (public_id) |p| try frame.dupeString(p) else "null";
    const sys_id = if (system_id) |s| try frame.dupeString(s) else "null";

    return frame._factory.node(DocumentType{
        ._proto = undefined,
        ._name = name,
        ._public_id = pub_id,
        ._system_id = sys_id,
    });
}

pub fn asNode(self: *DocumentType) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *DocumentType) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getName(self: *const DocumentType) []const u8 {
    return self._name;
}

pub fn getPublicId(self: *const DocumentType) []const u8 {
    return self._public_id;
}

pub fn getSystemId(self: *const DocumentType) []const u8 {
    return self._system_id;
}

pub fn isEqualNode(self: *const DocumentType, other: *const DocumentType) bool {
    return std.mem.eql(u8, self._name, other._name) and
        std.mem.eql(u8, self._public_id, other._public_id) and
        std.mem.eql(u8, self._system_id, other._system_id);
}

pub fn clone(self: *const DocumentType, frame: *Frame) !*DocumentType {
    return .init(self._name, self._public_id, self._system_id, frame);
}

pub fn remove(self: *DocumentType, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, frame);
}

// The rest of ChildNode, which a doctype carries like any other child node.
// Same three bodies CData has; there is no shared mixin here, and each of the
// three interfaces that implements ChildNode spells them out.
pub fn before(self: *DocumentType, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, node, frame);
    }
}

pub fn after(self: *DocumentType, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, viable_next, frame);
    }
}

pub fn replaceWith(self: *DocumentType, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const ref_node = self.asNode();
    const parent = ref_node.parentNode() orelse return;

    var rm_ref_node = true;
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }
        _ = try parent.insertBefore(child, ref_node, frame);
    }

    if (rm_ref_node) {
        _ = try parent.removeChild(ref_node, frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentType);

    pub const Meta = struct {
        pub const name = "DocumentType";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(DocumentType.getName, null, .{});
    pub const publicId = bridge.accessor(DocumentType.getPublicId, null, .{});
    pub const systemId = bridge.accessor(DocumentType.getSystemId, null, .{});
    pub const after = bridge.function(DocumentType.after, .{ .ce_reactions = true, .arity = 0 });
    pub const before = bridge.function(DocumentType.before, .{ .ce_reactions = true, .arity = 0 });
    pub const remove = bridge.function(DocumentType.remove, .{ .ce_reactions = true });
    pub const replaceWith = bridge.function(DocumentType.replaceWith, .{ .ce_reactions = true, .arity = 0 });
};
