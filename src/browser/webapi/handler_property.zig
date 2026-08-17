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

//! An `on*` property is not storage in front of a dispatch path: per DOM, an
//! event handler *is* an event listener. It joins its target's listener list
//! the moment the property is first set and runs from that place, so a
//! handler set after an addEventListener listener runs after it.
//!
//! Keeping the function in a field on the owner cannot express that, which is
//! why every handler property goes through the store on the global's event
//! manager instead. `accessors(T, .onfoo).get` / `.set` is the getter/setter
//! pair for one such property on a type that can hand out its EventTarget.

const js = @import("../js/js.zig");
const global_event_handlers = @import("global_event_handlers.zig");

const Execution = js.Execution;

/// The getter/setter pair for `T`'s `on*` property named by `handler`.
/// `T` must expose `asEventTarget`.
pub fn accessors(comptime T: type, comptime handler: global_event_handlers.Handler) type {
    return struct {
        pub fn get(self: *T, exec: *const Execution) ?js.Function.Global {
            return exec.getEventHandler(self.asEventTarget(), handler);
        }

        pub fn set(self: *T, callback: ?js.Function.Global, exec: *const Execution) !void {
            return exec.setEventHandler(self.asEventTarget(), handler, callback);
        }
    };
}
