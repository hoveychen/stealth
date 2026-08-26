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

//! The `SVGZoomAndPan` mixin, which `<svg>` and `<view>` both include.
//!
//! `zoomAndPan` is not an `SVGAnimatedEnumeration`: it is a plain
//! `unsigned short` backed by a field that *two* things write, and the
//! difference is observable. Measured on a headed Chrome 151
//! (`probes/expr-svg-family-edges.js`):
//!
//!   svg.zoomAndPan                          2   (magnify, the initial value)
//!   svg.zoomAndPan = 1                      1   and getAttribute() stays ''
//!   setAttribute('zoomAndPan', 'disable')   1
//!   setAttribute('zoomAndPan', 'DISABLE')   0   the keywords are case-sensitive
//!   setAttribute('zoomAndPan', 'bogus')     0   invalid is UNKNOWN, not magnify
//!   removeAttribute('zoomAndPan')           0   and *not* back to the initial 2
//!   svg.zoomAndPan = 7                      unchanged; out of range is ignored
//!
//! So the IDL setter writes the field without touching the attribute, and the
//! attribute writes the field whenever it is parsed -- including on removal,
//! which is why a `<svg>` that never carried the attribute reads 2 and one that
//! carried and lost it reads 0.
//!
//! There is no attribute-changed hook to parse from, so the state re-reads the
//! attribute on every get and re-parses only when its *classification* changed.
//! Classification is all the value depends on, so that is the same answer
//! Blink's eager parse gives, one read later. The one sequence it cannot see is
//! an attribute that moves between two values of the same class -- `bogus` to
//! `rubbish` with an IDL write in between -- where Blink would reset to UNKNOWN
//! and this keeps the written value.
const std = @import("std");

const Element = @import("../../Element.zig");

pub const unknown: u16 = 0;
pub const disable: u16 = 1;
pub const magnify: u16 = 2;

/// What the content attribute currently says, reduced to the three cases the
/// value depends on. `none` is the absent attribute.
const Keyword = enum {
    none,
    disable,
    magnify,
    other,

    fn of(attribute: ?[]const u8) Keyword {
        const text = attribute orelse return .none;
        if (std.mem.eql(u8, text, "disable")) return .disable;
        if (std.mem.eql(u8, text, "magnify")) return .magnify;
        return .other;
    }

    fn value(self: Keyword) u16 {
        return switch (self) {
            .disable => disable,
            .magnify => magnify,
            .none, .other => unknown,
        };
    }
};

pub const State = struct {
    _value: u16 = magnify,
    // Null until the attribute has been looked at once, so an element that
    // never carried it keeps the initial magnify instead of parsing its
    // absence into UNKNOWN.
    _seen: ?Keyword = null,

    pub fn get(self: *State, element: *const Element) u16 {
        const current: Keyword = .of(element.getAttributeSafe(comptime .wrap("zoomAndPan")));
        if (self._seen) |seen| {
            if (seen != current) {
                self._value = current.value();
            }
        } else if (current != .none) {
            self._value = current.value();
        }
        self._seen = current;
        return self._value;
    }

    pub fn set(self: *State, element: *const Element, value: u16) void {
        // The get is not for its answer: it settles any attribute change that
        // happened since the last read, so this write lands on top of it
        // rather than under it.
        _ = self.get(element);
        if (value <= magnify) {
            self._value = value;
        }
    }
};
