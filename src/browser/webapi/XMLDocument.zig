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

const Document = @import("Document.zig");
const Node = @import("Node.zig");

const XMLDocument = @This();

pub const Proto = Document;

_proto: *Document,

pub fn asDocument(self: *XMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *XMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *XMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLDocument);

    pub const Meta = struct {
        pub const name = "XMLDocument";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// The named objects are a Document's, not an HTML document's, so an XML
    /// one answers them too -- and needs its own handler to do it, since V8
    /// does not inherit one. See Document.NamedObjectAccess.
    const named_objects = Document.NamedObjectAccess(XMLDocument);
    pub const @"[str]" = bridge.namedIndexedFull(named_objects.get, null, named_objects.delete, named_objects.names, named_objects.query, named_objects.define, null, .{ .null_as_undefined = true, .masking = true });
};
