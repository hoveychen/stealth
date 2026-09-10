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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

const Event = @import("../Event.zig");
const EventManagerBase = @import("../../EventManagerBase.zig");
const EventTarget = @import("../EventTarget.zig");

const FontFace = @import("FontFace.zig");
const style_resources = @import("../../frame/style_resources.zig");

const FontFaceSet = @This();

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{ FontFaceSet, ValueIterator, EntryIterator };
}

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_proto: *EventTarget,
_arena: *lp.Arena,
// The faces `add()` was given. Nothing here loads a font -- `status` stays
// "loaded" and `check` stays true -- but the set has to remember what it was
// handed, because a page walks it back out: `for (const f of document.fonts)`.
_faces: std.ArrayList(*FontFace) = .empty,

/// The `StyleManager.sheet_version` the declared half of `_faces` was derived
/// under, or null when it has never been derived. A page can inject
/// `@font-face` rules at any time -- 310 of iphey's 312 arrive between DCL and
/// load, as a font enumeration probe -- and Chrome's set reflects them
/// synchronously, so the derivation is redone lazily on every read rather than
/// once during the style-resource pass.
_sheet_version: ?usize = null,

/// Resolved when the last `@font-face` file in flight has arrived. Created on
/// the first read of `ready` while a fetch is outstanding, and null the rest of
/// the time -- a page that asks after everything has landed gets an
/// already-resolved promise, which is what it would get in Chrome too.
_ready: ?js.PromiseResolver.Global = null,

pub fn init(exec: *const Execution) !*FontFaceSet {
    const arena = try exec.getArena(.tiny, "FontFaceSet");
    errdefer arena.release();

    return exec._factory.eventTargetWithAllocator(arena.allocator(), FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
    });
}

pub fn deinit(self: *FontFaceSet, page: *Page) void {
    // The set holds a reference to every face it was handed, so it has to give
    // them back: a FontFace owns an arena, and an extra reference outliving the
    // page is a leaked arena (the test runner panics on those).
    for (self._faces.items) |face| {
        face.releaseRef(page);
    }
    self._arena.release();
}

pub fn releaseRef(self: *FontFaceSet, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFaceSet) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FontFaceSet) *EventTarget {
    return self._proto;
}

// Readonly, and answered from a getter because the kind is what a bot check
// reads (see src/browser/tests/descriptor_kind.html).
pub fn getSize(self: *FontFaceSet, exec: *const Execution) u32 {
    self.syncDeclared(exec);
    return @intCast(self._faces.items.len);
}

/// Bring the declared half of the set back in line with the stylesheets, if
/// they have moved since the last look. The script-added half is never touched.
///
/// Ordering follows Chrome: the declared faces in source order, and whatever
/// `add()` was handed after them.
///
/// Failure is silent and leaves the previous contents in place. A read of
/// `document.fonts.size` is not a place to raise, and the alternative -- an
/// empty set on one bad allocation -- is worse than a stale one.
fn syncDeclared(self: *FontFaceSet, exec: *const Execution) void {
    const frame = switch (exec.js.global) {
        .frame => |frame| frame,
        // A worker has no stylesheets, so there is nothing to derive and the
        // script-added faces are the whole set.
        .worker => return,
    };

    const version = frame._style_manager.sheet_version;
    if (self._sheet_version) |seen| {
        if (seen == version) return;
    }

    const arena = self._arena.allocator();
    const declared = style_resources.declaredFaces(frame, arena) catch return;

    var rebuilt: std.ArrayList(*FontFace) = .empty;
    rebuilt.ensureTotalCapacity(arena, declared.len + self._faces.items.len) catch return;

    for (declared) |face| {
        // Reuse the existing object when the same family is still declared, so
        // a face that has already loaded keeps saying so and a page holding a
        // reference to it keeps holding the same one.
        if (self.findDeclared(face.family, face.weight, face.style, rebuilt.items)) |existing| {
            rebuilt.appendAssumeCapacity(existing);
            continue;
        }
        const entry = FontFace.init(face.family, "", .{
            .weight = face.weight,
            .style = face.style,
        }, exec) catch continue;
        // A face that arrives after the style-resource pass was never fetched,
        // which is what Chrome reports for one too: every face iphey injects
        // reads `unloaded` there.
        entry.markDeclared(false);
        // Appending bypasses `add()`, which is where the reference is normally
        // taken. Without this the set holds a face at zero and the runner
        // catches the double release on teardown.
        entry.acquireRef();
        rebuilt.appendAssumeCapacity(entry);
    }

    // The script's faces keep their own order, after the declared ones.
    for (self._faces.items) |face| {
        if (face.isDeclared()) continue;
        rebuilt.appendAssumeCapacity(face);
    }

    // A declared face whose rule is gone loses its reference here.
    for (self._faces.items) |face| {
        if (!face.isDeclared()) continue;
        for (rebuilt.items) |kept| {
            if (kept == face) break;
        } else face.releaseRef(frame._page);
    }

    self._faces = rebuilt;
    self._sheet_version = version;
}

/// The existing object for one declared rule, or null to build a new one.
///
/// A rule is identified by its family AND the two descriptors the scan carries,
/// because one family routinely ships several rules -- a 400 and a 700 are the
/// ordinary way to serve a font -- and Chrome keeps one FontFace per rule.
/// Matching on the family alone handed the same object back for every rule in
/// the family, so a rebuild appended it once per rule while owning a single
/// reference to it, and teardown then released it once per slot: `release
/// overflow` on an already-freed FontFace (tests/css/font_face_family_dupes.html).
///
/// `taken` is what this rebuild has already claimed. Two rules may be identical
/// in all three fields, and an existing object may only be reused once even
/// then -- which is the half that keeps the count right rather than the
/// descriptors.
fn findDeclared(
    self: *const FontFaceSet,
    family: []const u8,
    weight: []const u8,
    style: []const u8,
    taken: []const *FontFace,
) ?*FontFace {
    for (self._faces.items) |face| {
        if (!face.isDeclared()) continue;
        if (!std.mem.eql(u8, face.getFamily(), family)) continue;
        if (!std.mem.eql(u8, face.getWeight(), weight)) continue;
        if (!std.mem.eql(u8, face.getStyle(), style)) continue;
        for (taken) |claimed| {
            if (claimed == face) break;
        } else return face;
    }
    return null;
}

/// `loading` while a declared face's file is still on the wire, `loaded` once
/// they have all landed.
///
/// This used to be the constant "loaded", on the grounds that a headless
/// browser does not load fonts. It does now -- font_file.zig reads the metrics
/// out of the bytes -- so a page polling `status` while its webfont is in
/// flight would have been told the opposite of what `ready` was about to do.
pub fn getStatus(_: *const FontFaceSet, exec: *const Execution) []const u8 {
    return if (pending(exec) > 0) "loading" else "loaded";
}

/// A promise for "every declared face has arrived".
///
/// Already resolved when nothing is in flight, which is the common case and
/// what the old constant was right about. While a fetch is outstanding the
/// resolver is persisted and settled by `settle` below, called from the frame
/// when the last font transfer finishes -- so `await document.fonts.ready`
/// followed by a measurement now sees the webfont's advances rather than the
/// fallback's.
pub fn getReady(self: *FontFaceSet, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._ready) |resolver| {
        return local.toLocal(resolver).promise();
    }
    if (pending(exec) == 0) {
        return local.resolvePromise({});
    }
    const resolver = local.createPromiseResolver();
    self._ready = try resolver.persist();
    return resolver.promise();
}

/// Called by the frame when the last `@font-face` transfer settles.
///
/// Opens its own local scope rather than reading `exec.js.local`: this runs
/// from a scheduler task, and there `exec.js.local` is null even though the
/// context has been entered. Resolving through the null one fails silently,
/// which reads exactly like `ready` never having been wired up (measured --
/// `has_ready = true`, `has_local = false`). `webapi/Scheduler.zig` settles
/// its own promises the same way.
pub fn settle(self: *FontFaceSet, exec: *Execution) void {
    const resolver = self._ready orelse return;
    self._ready = null;
    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();
    ls.local.toLocal(resolver).resolve("FontFaceSet.ready", {});
}

/// How many declared faces are still on the wire. A worker has no document and
/// so no faces, which is why this is not simply a field on the set.
fn pending(exec: *const Execution) usize {
    return switch (exec.js.global) {
        .frame => |frame| frame._webfonts_pending,
        .worker => 0,
    };
}

/// Whether the text could be rendered with the font this shorthand names.
///
/// The answer follows the SET, not the name. Measured on Chrome 151 with
/// three `@font-face` rules in the page (scratch/ff/fontfaceset.mjs):
///
///   a family NOTHING declares          true    (`NoSuchFontXYZ`, `Courier New`)
///   a declared face that has loaded    true
///   a declared face still `unloaded`   FALSE
///
/// That last row is the one this used to get wrong by answering true for
/// everything -- and the first row is the half it got right, which is why the
/// constant looked correct for so long.
///
/// Only the family matters here. The size, style and weight in the shorthand
/// are parsed off and dropped: matching a face's weight against the
/// shorthand's is a further question, and nothing measured yet turns on it.
pub fn check(self: *FontFaceSet, font: []const u8, exec: *const Execution) bool {
    self.syncDeclared(exec);
    var it = familyList(font);
    while (it.next()) |family| {
        for (self._faces.items) |face| {
            if (!std.ascii.eqlIgnoreCase(face.getFamily(), family)) continue;
            // A face this document declares decides the answer, and an
            // unloaded one decides it `false`.
            if (std.mem.eql(u8, face.getStatus(), "loaded")) break;
            return false;
        }
    }
    return true;
}

/// The families a `font` shorthand names, in order, unquoted and untrimmed of
/// nothing else. Everything up to and including the last size-ish token is
/// dropped: `16px "Courier New", monospace` yields `Courier New` then
/// `monospace`.
fn familyList(font: []const u8) FamilyIterator {
    // The family list starts after the size, and the size is the last token
    // that begins with a digit or a `.` -- `bold italic 16px/1.5 Arial` ends
    // its non-family part at `16px/1.5`.
    var rest = std.mem.trim(u8, font, &std.ascii.whitespace);
    var tokens = std.mem.tokenizeAny(u8, rest, " \t\n\r");
    var after: usize = 0;
    while (tokens.next()) |token| {
        const c = token[0];
        if (std.ascii.isDigit(c) or c == '.') {
            after = (@intFromPtr(token.ptr) - @intFromPtr(rest.ptr)) + token.len;
        }
    }
    if (after != 0 and after <= rest.len) rest = rest[after..];
    return .{ .rest = rest };
}

const FamilyIterator = struct {
    rest: []const u8,

    fn next(self: *FamilyIterator) ?[]const u8 {
        while (self.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const raw = self.rest[0..end];
            self.rest = if (end == self.rest.len) "" else self.rest[end + 1 ..];
            const family = std.mem.trim(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), "\"'");
            if (family.len != 0) return family;
        }
        return null;
    }
};

// load(font, text?) - resolves immediately with an empty array.
pub fn load(self: *FontFaceSet, font: []const u8, exec: *const Execution) !js.Promise {
    // TODO parse font to check if the font has been added before dispatching
    // events.
    _ = font;

    const target = self.asEventTarget();
    try dispatch(exec, target, "loading");
    try dispatch(exec, target, "loadingdone");

    return exec.js.local.?.resolvePromise({});
}

// Into the asking realm's own listener list. Both globals carry the same two
// members -- a frame through the DOM-aware EventManager, which also keeps
// `window.event` pointed at the event being dispatched, and a worker directly --
// so the split is over which one to ask, not over what to do.
fn dispatch(exec: *const Execution, target: *EventTarget, comptime typ: []const u8) !void {
    const opts: EventManagerBase.DispatchDirectOptions = .{ .context = "load font face set" };
    switch (exec.js.global) {
        .frame => |frame| {
            if (frame._event_manager.hasDirectListeners(target, typ, null) == false) {
                return;
            }
            const event = try Event.initTrusted(comptime .wrap(typ), .{}, frame._page);
            try frame._event_manager.dispatchDirect(target, event, null, opts);
        },
        .worker => |worker| {
            if (worker.hasDirectListeners(target, typ, null) == false) {
                return;
            }
            const event = try Event.initTrusted(comptime .wrap(typ), .{}, worker._page);
            try worker.dispatch(target, event, null, opts);
        },
    }
}

// The setlike half. Chrome's semantics, measured
// (tools/fingerprint/probes/expr-fontfaceset.js): `add` is idempotent per face
// and answers the set, `delete` answers whether it removed anything, `clear`
// answers undefined, and all three refuse anything that is not a FontFace.
pub fn add(self: *FontFaceSet, face: *FontFace) !*FontFaceSet {
    if (self.indexOf(face) != null) {
        return self;
    }
    face.acquireRef();
    try self._faces.append(self._arena.allocator(), face);
    return self;
}

pub fn delete(self: *FontFaceSet, face: *FontFace, exec: *const Execution) bool {
    const index = self.indexOf(face) orelse return false;
    // orderedRemove, not swapRemove: iteration order is insertion order, and a
    // page that adds three faces and deletes the first still walks the other
    // two in the order it added them.
    _ = self._faces.orderedRemove(index);
    face.releaseRef(exec.page);
    return true;
}

pub fn clear(self: *FontFaceSet, exec: *const Execution) void {
    for (self._faces.items) |face| {
        face.releaseRef(exec.page);
    }
    self._faces.clearRetainingCapacity();
}

pub fn has(self: *const FontFaceSet, face: *FontFace) bool {
    return self.indexOf(face) != null;
}

fn indexOf(self: *const FontFaceSet, face: *FontFace) ?usize {
    for (self._faces.items, 0..) |candidate, i| {
        if (candidate == face) {
            return i;
        }
    }
    return null;
}

pub fn values(self: *FontFaceSet, exec: *const Execution) !*ValueIterator {
    self.syncDeclared(exec);
    return .init(.{ .set = self }, exec);
}

pub fn entries(self: *FontFaceSet, exec: *const Execution) !*EntryIterator {
    self.syncDeclared(exec);
    return .init(.{ .set = self }, exec);
}

// A set's callback is handed the value twice and the set third, same as
// Set.prototype.forEach.
pub fn forEach(self: *FontFaceSet, cb_: js.Function, js_this_: ?js.Object, exec: *const Execution) !void {
    self.syncDeclared(exec);
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
    for (self._faces.items) |face| {
        var caught: js.TryCatch.Caught = .{};
        cb.tryCall(void, .{ face, face, self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "FontFaceSet" });
        };
    }
}

pub const Iterator = struct {
    index: usize = 0,
    set: *FontFaceSet,

    pub const Entry = struct { *FontFace, *FontFace };

    pub fn next(self: *Iterator, _: *const Execution) ?Entry {
        const index = self.index;
        if (index >= self.set._faces.items.len) {
            return null;
        }
        self.index = index + 1;
        const face = self.set._faces.items[index];
        return .{ face, face };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome 151's own `Object.getOwnPropertyNames(FontFaceSet.prototype)`
    // order, measured; `constructor` is the bridge's and lands last.
    pub const onloading = bridge.accessor(handlerProperty(FontFaceSet, .onloading).get, handlerProperty(FontFaceSet, .onloading).set, .{});
    pub const onloadingdone = bridge.accessor(handlerProperty(FontFaceSet, .onloadingdone).get, handlerProperty(FontFaceSet, .onloadingdone).set, .{});
    pub const onloadingerror = bridge.accessor(handlerProperty(FontFaceSet, .onloadingerror).get, handlerProperty(FontFaceSet, .onloadingerror).set, .{});
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
    pub const clear = bridge.function(FontFaceSet.clear, .{});
    pub const delete = bridge.function(FontFaceSet.delete, .{});
    pub const entries = bridge.function(FontFaceSet.entries, .{});
    pub const forEach = bridge.function(FontFaceSet.forEach, .{ .arity = 1 });
    pub const has = bridge.function(FontFaceSet.has, .{});
    // Chrome hands out one function object under both names; the bridge builds
    // two, which is the same shape every other collection here has.
    pub const keys = bridge.function(FontFaceSet.values, .{});
    pub const values = bridge.function(FontFaceSet.values, .{});
    pub const symbol_iterator = bridge.iterator(FontFaceSet.values, .{ .js_name = "values" });
};

const testing = @import("../../../testing.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties; per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
    try testing.htmlRunner("css/font_face_family_dupes.html", .{});
}
