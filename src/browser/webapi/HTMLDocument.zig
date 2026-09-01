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

const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const Node = @import("Node.zig");
const Document = @import("Document.zig");

const HTMLDocument = @This();

pub const Proto = Document;

_proto: *Document,

pub fn asDocument(self: *HTMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *HTMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *HTMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

// HTMLDocument adds nothing of its own: the whole HTML-flavoured document
// surface (title / body / head / images / ... ) is declared on Document, which
// is where a headed Chrome 150 puts it. Chrome's HTMLDocument.prototype holds
// only `constructor`, and this interface matches that.
pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLDocument);

    pub const Meta = struct {
        pub const name = "HTMLDocument";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// `document.myForm`. The list is Document's, but the handler has to be
    /// installed here too: V8 does not give a derived instance template its
    /// base's named handler, and the document every page has is this one.
    const named_objects = Document.NamedObjectAccess(HTMLDocument);
    pub const @"[str]" = bridge.namedIndexedFull(named_objects.get, null, named_objects.delete, named_objects.names, named_objects.query, named_objects.define, null, .{ .null_as_undefined = true });

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*HTMLDocument {
        return frame._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }
};
