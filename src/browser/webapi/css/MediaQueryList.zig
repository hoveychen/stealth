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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const MediaQuery = @import("../../css/MediaQuery.zig");
const Window = @import("../Window.zig");
const MediaQueryListEvent = @import("../event/css_events.zig").MediaQueryListEvent;

const log = lp.log;

const MediaQueryList = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_frame: *Frame,
_media: []const u8,
// What listeners last observed; `change` fires when the viewport flips it.
_matches: bool,

/// The query as the page wrote it. `_media` is the canonical form and it is
/// LOSSY -- a number in it is written to six significant figures -- so it is
/// what `media` reports and never what `matches` reads. A guard bisecting
/// `devicePixelRatio` walks past the sixth figure within a dozen steps.
_query: []const u8,

/// `_media` is the canonical form of the query, not the text handed in -- see
/// the serialisation section of css/MediaQuery.zig. Both are kept, because the
/// canonical form rounds every number in it to six significant figures:
/// `matches` reading it back answered `(min-resolution: 2.00000011920929dppx)`
/// against 2.00000, which is one rung of the ladder Kasada bisects
/// devicePixelRatio with (measured, probes/expr-b96-resolution-boundary.js).
pub fn init(query: []const u8, frame: *Frame) !*MediaQueryList {
    const raw = try frame.arena.dupe(u8, query);
    const self = try frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try MediaQuery.serialize(frame.arena, raw),
        ._query = raw,
        ._frame = frame,
        ._matches = MediaQuery.matches(raw, frame.viewport()),
    });
    try frame._media_query_lists.append(frame.arena, self);
    return self;
}

pub fn deinit(self: *MediaQueryList) void {
    _ = self;
}

pub fn asEventTarget(self: *MediaQueryList) *EventTarget {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryList) []const u8 {
    return self._media;
}

/// Re-evaluates the stored query against the current viewport on every call
/// so the result stays in sync with viewport emulation. The viewport is the
/// frame's own -- the page's for the top-level frame (overridable via
/// Emulation.setDeviceMetricsOverride), the `<iframe>` element's box for a child
/// -- matching `Window.innerWidth` / `innerHeight`. A `(max-width: 400px)` query
/// matches inside a 300x65 frame on a 1920-wide page, measured on Chrome 151.
pub fn getMatches(self: *const MediaQueryList, frame: *Frame) bool {
    return MediaQuery.matches(self._query, frame.viewport());
}

pub fn viewportChanged(self: *MediaQueryList) void {
    const matches = self.getMatches(self._frame);
    if (matches == self._matches) return;
    self._matches = matches;

    const frame = self._frame;
    // `null` for the property handler: unlike upstream this fork keeps `onchange`
    // in the frame's attribute-listener store (see the `onchange` accessor
    // below), so there is no `_on_change` field to pass.
    if (!frame.hasDirectListeners(self.asEventTarget(), "change", null)) return;
    self.dispatchChange(matches) catch |err| {
        log.warn(.browser, "matchMedia change", .{ .err = err, .media = self._media });
    };
}

fn dispatchChange(self: *MediaQueryList, matches: bool) !void {
    const frame = self._frame;
    const event = try MediaQueryListEvent.initTrusted(comptime .wrap("change"), .{
        .matches = matches,
        .media = self._media,
    }, frame);
    try frame.dispatch(self.asEventTarget(), event.asEvent(), null, .{ .context = "MediaQueryList change" });
}

pub fn addListener(self: *MediaQueryList, cb_: ?js.Function, exec: *js.Execution) !void {
    const cb = cb_ orelse return;
    try self._proto.addEventListener("change", .{ .value = .{ .function = cb } }, null, exec);
}

pub fn removeListener(self: *MediaQueryList, cb_: ?js.Function, exec: *js.Execution) !void {
    const cb = cb_ orelse return;
    try self._proto.removeEventListener("change", .{ .value = .{ .function = cb } }, null, exec);
}

/// Measured on Chrome 150: MediaQueryList.prototype carries `onchange`, between
/// `matches` and `addListener`. It goes through the frame's attribute-listener
/// store, the same mechanism Document and Element use, so a plain
/// `dispatchEvent(new MediaQueryListEvent('change'))` reaches it.
fn handlerAccessor(comptime handler: @import("../global_event_handlers.zig").Handler) type {
    return struct {
        pub fn get(self: *MediaQueryList, frame: *Frame) ?js.Function.Global {
            return frame.getEventHandler(self.asEventTarget(), handler);
        }

        pub fn set(self: *MediaQueryList, setter: ?Window.FunctionSetter, frame: *Frame) !void {
            return frame.setEventHandler(self.asEventTarget(), handler, Window.getFunctionFromSetter(setter));
        }
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryList);

    pub const Meta = struct {
        pub const name = "MediaQueryList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const media = bridge.accessor(MediaQueryList.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryList.getMatches, null, .{});
    pub const onchange = bridge.accessor(handlerAccessor(.onchange).get, handlerAccessor(.onchange).set, .{});
    pub const addListener = bridge.function(MediaQueryList.addListener, .{});
    pub const removeListener = bridge.function(MediaQueryList.removeListener, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaQueryList" {
    try testing.htmlRunner("css/media_query_list.html", .{});
}

test "WebApi: media @-rule cascade" {
    try testing.htmlRunner("css/media_at_rule_cascade.html", .{});
}

test "WebApi: CSS events" {
    try testing.htmlRunner("css/css_events.html", .{});
}

test "WebApi: MediaQueryList change survives iframe renavigation" {
    const page = try testing.pageTest("runner/iframe_idle.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    const frame = page.frame().?;
    const child = frame.child_frames.items[1];
    {
        var ls: js.Local.Scope = undefined;
        child.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("matchMedia('(max-width: 500px)').addListener(() => {});", null);
    }
    try testing.expectEqual(1, child._media_query_lists.items.len);

    // Re-navigating the iframe re-inits the Frame in place and destroys its
    // JS context; the old document's lists must go with it.
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("document.querySelectorAll('iframe')[1].src = 'runner1.html';", null);
    }
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    try testing.expectEqual(true, child == frame.child_frames.items[1]);
    try testing.expectEqual(0, child._media_query_lists.items.len);

    // And the new document registers its own. No assertion that a viewport
    // override then fires `change` *in the child*: unlike upstream, a child
    // frame's viewport here is the iframe element's box (Frame.viewport), so a
    // page-level override does not move it and nothing legitimately flips.
    // The firing half is covered on a root frame by the next test.
    var ls: js.Local.Scope = undefined;
    child.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec("matchMedia('(max-width: 500px)').addListener(() => {});", null);
    try testing.expectEqual(1, child._media_query_lists.items.len);
}

test "WebApi: MediaQueryList created during a change listener waits for the next change" {
    const page = try testing.pageTest("hi.html", .{});
    defer page.close();

    const frame = page.frame().?;
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\window.fired = [];
            \\matchMedia('(max-width: 500px)').addListener(e => {
            \\  fired.push('outer:' + e.matches);
            \\  matchMedia('(max-width: 600px)').addListener(e => fired.push('inner:' + e.matches));
            \\});
        , null);
    }

    const browser = page.session.browser;
    defer browser.setViewportOverride(null);

    // The inner list is created at 400px, where it already matches.
    browser.setViewportOverride(.{ .width = 400, .height = 800, .scale = 1 });
    try testing.expectEqual(2, frame._media_query_lists.items.len);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("fired.join() === 'outer:true'", null);
        try testing.expect(v.toBool());
    }

    // Both flip at 700px. The outer listener creates a third list which,
    // again, has nothing to report.
    browser.setViewportOverride(.{ .width = 700, .height = 800, .scale = 1 });
    try testing.expectEqual(3, frame._media_query_lists.items.len);
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("fired.join() === 'outer:true,outer:false,inner:false'", null);
    try testing.expect(v.toBool());
}
