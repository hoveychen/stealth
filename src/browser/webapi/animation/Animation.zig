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
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const services = @import("../document/services.zig");

const log = lp.log;

const Animation = @This();

/// Measured on Chrome 150: Animation is an EventTarget, and CSSAnimation /
/// CSSTransition hang off it. Without this layer `new Animation() instanceof
/// EventTarget` is false and addEventListener is missing entirely.
pub const Proto = EventTarget;

/// Measured: `replaceState` starts at "active" and `persist()` moves it to
/// "persisted".
const ReplaceState = enum {
    active,
    persisted,
    removed,
};

const PlayState = enum {
    idle,
    running,
    paused,
    finished,
};

_proto: *EventTarget,
_rc: lp.RC = .{},
_frame: *Frame,
_arena: *lp.Arena,

_effect: ?js.Object.Global = null,
_timeline: ?*services.DocumentTimeline = null,
_ready_resolver: ?js.PromiseResolver.Global = null,
_finished_resolver: ?js.PromiseResolver.Global = null,
_startTime: ?f64 = null,
_playState: PlayState = .idle,
_current_time: ?f64 = null,
_playback_rate: f64 = 1,
_id: []const u8 = "",
_replace_state: ReplaceState = .active,

// Fake the animation by passing the states:
// .idle => .running once play() is called.
// .running => .finished after 10ms when update() is callback.
//
// TODO add support for effect and timeline
pub fn init(frame: *Frame) !*Animation {
    const arena = try frame.getArena(.tiny, "Animation");
    errdefer arena.release();

    return frame._factory.eventTargetWithAllocator(arena.allocator(), Animation{
        ._proto = undefined,
        ._frame = frame,
        ._arena = arena,
    });
}

pub fn asEventTarget(self: *Animation) *EventTarget {
    return self._proto;
}

/// `new Animation(effect, timeline)`. Measured: both arguments are optional, so
/// Chrome reports Animation.length === 0, and a bare `new Animation()` is legal.
pub fn construct(effect: ?js.Object.Global, timeline: ?*services.DocumentTimeline, frame: *Frame) !*Animation {
    const self = try init(frame);
    self._effect = effect;
    self._timeline = timeline;
    return self;
}

pub fn deinit(self: *Animation, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Animation, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Animation) void {
    self._rc.acquire();
}

pub fn play(self: *Animation, frame: *Frame) !void {
    if (self._playState == .running) {
        return;
    }

    // transition to running.
    self._playState = .running;

    // Schedule the transition from .running => .finished in 10ms.
    self.acquireRef();
    errdefer self.releaseRef(frame._page);
    try frame.js.scheduler.add(
        self,
        Animation.update,
        10,
        .{ .name = "animation.update", .finalizer = Animation.cancelled },
    );
}

// The scheduler drops pending tasks when the context is torn down. `update`
// and `cancelled` are mutually exclusive, so play()'s ref is released once.
fn cancelled(ctx: *anyopaque) void {
    const self: *Animation = @ptrCast(@alignCast(ctx));
    self.releaseRef(self._frame._page);
}

pub fn pause(self: *Animation) void {
    self._playState = .paused;
}

pub fn cancel(self: *Animation) void {
    // Transition to idle. If the animation was .running, the already-scheduled
    // update() callback will fire but see .idle state, skip the finish
    // transition, and release the strong ref via weakRef() as normal.
    self._playState = .idle;
}

pub fn finish(self: *Animation, frame: *Frame) void {
    if (self._playState == .finished) {
        return;
    }

    self._playState = .finished;

    // resolve finished
    if (self._finished_resolver) |resolver| {
        frame.js.local.?.toLocal(resolver).resolve("Animation.getFinished", self);
    }
    // call onfinish
    if (self.getOnFinish()) |func| {
        frame.js.local.?.toLocal(func).call(void, .{}) catch |err| {
            log.warn(.js, "Animation.onfinish", .{ .err = err });
        };
    }
}

pub fn reverse(_: *Animation) void {
    log.warn(.not_implemented, "Animation.reverse", .{});
}

pub fn getFinished(self: *Animation, frame: *Frame) !js.Promise {
    if (self._finished_resolver == null) {
        const resolver = frame.js.local.?.createPromiseResolver();
        self._finished_resolver = try resolver.persist();
        return resolver.promise();
    }
    return frame.js.toLocal(self._finished_resolver).?.promise();
}

// The ready promise is immediately resolved.
pub fn getReady(self: *Animation, frame: *Frame) !js.Promise {
    if (self._ready_resolver == null) {
        const resolver = frame.js.local.?.createPromiseResolver();
        resolver.resolve("Animation.getReady", self);
        self._ready_resolver = try resolver.persist();
        return resolver.promise();
    }
    return frame.js.toLocal(self._ready_resolver).?.promise();
}

pub fn getEffect(self: *const Animation) ?js.Object.Global {
    return self._effect;
}

pub fn setEffect(self: *Animation, effect: ?js.Object.Global) !void {
    self._effect = effect;
}

/// Measured: a fresh Animation already reports the document's timeline, not
/// null.
pub fn getTimeline(self: *Animation, frame: *Frame) !?*services.DocumentTimeline {
    if (self._timeline) |timeline| {
        return timeline;
    }
    const timeline = try services.DocumentTimeline.init(frame);
    self._timeline = timeline;
    return timeline;
}

pub fn setTimeline(self: *Animation, timeline: ?*services.DocumentTimeline) !void {
    self._timeline = timeline;
}

pub fn getStartTime(self: *const Animation) ?f64 {
    return self._startTime;
}

pub fn setStartTime(self: *Animation, value: ?f64, frame: *Frame) !void {
    self._startTime = value;

    // if the startTime is null, don't play the animation.
    if (value == null) {
        return;
    }

    return self.play(frame);
}

// The property lives in the handler store, so it also takes its place in the
// listener list; `update` and `finish` still call it directly rather than
// dispatching an AnimationPlaybackEvent, which is a separate gap.
pub fn getOnFinish(self: *Animation) ?js.Function.Global {
    return self._frame.getEventHandler(self.asEventTarget(), .onfinish);
}

// callback function transitioning from a state to another
fn update(ctx: *anyopaque) !?u32 {
    const self: *Animation = @ptrCast(@alignCast(ctx));

    switch (self._playState) {
        .running => {
            // transition to finished.
            self._playState = .finished;

            var ls: js.Local.Scope = undefined;
            self._frame.js.localScope(&ls);
            defer ls.deinit();

            // resolve finished
            if (self._finished_resolver) |resolver| {
                ls.toLocal(resolver).resolve("Animation.getFinished", self);
            }
            // call onfinish
            if (self.getOnFinish()) |func| {
                ls.toLocal(func).call(void, .{}) catch |err| {
                    log.warn(.js, "Animation.onfinish", .{ .err = err });
                };
            }
        },
        .idle, .paused, .finished => {},
    }

    // No future change scheduled, set the object weak for garbage collection.
    self.releaseRef(self._frame._page);
    return null;
}

pub fn setOnFinish(self: *Animation, cb: ?js.Function.Global) !void {
    return self._frame.setEventHandler(self.asEventTarget(), .onfinish, cb);
}

pub fn playState(self: *const Animation) []const u8 {
    return @tagName(self._playState);
}

/// Measured: pending is an accessor on Chrome, not a data property, and a
/// fresh animation is not pending. Nothing here ever enters the pending state
/// because play() takes effect synchronously.
pub fn getPending(_: *const Animation) bool {
    return false;
}

pub fn getCurrentTime(self: *const Animation) ?f64 {
    return self._current_time;
}

pub fn setCurrentTime(self: *Animation, value: ?f64) !void {
    self._current_time = value;
}

pub fn getPlaybackRate(self: *const Animation) f64 {
    return self._playback_rate;
}

pub fn setPlaybackRate(self: *Animation, value: f64) !void {
    self._playback_rate = value;
}

/// Measured: `updatePlaybackRate` is the "seamless" setter, and with no running
/// effect it lands on the same value the plain setter would.
pub fn updatePlaybackRate(self: *Animation, value: f64) !void {
    self._playback_rate = value;
}

/// Measured: both range ends read back the string "normal" on a fresh
/// animation. They are accessor pairs, but we do not model timeline ranges, so
/// the setter is deliberately a no-op rather than a lie about what it stored.
pub fn getRangeStart(_: *const Animation) []const u8 {
    return "normal";
}

pub fn setRangeStart(_: *Animation, _: ?js.Value) void {}

pub fn getRangeEnd(_: *const Animation) []const u8 {
    return "normal";
}

pub fn setRangeEnd(_: *Animation, _: ?js.Value) void {}

pub fn getReplaceState(self: *const Animation) []const u8 {
    return @tagName(self._replace_state);
}

pub fn persist(self: *Animation) void {
    self._replace_state = .persisted;
}

pub fn getId(self: *const Animation) []const u8 {
    return self._id;
}

pub fn setId(self: *Animation, value: []const u8, frame: *Frame) !void {
    self._id = try frame.dupeString(value);
}

/// Measured: null on a fresh animation -- there is no progress to report until
/// an effect is attached.
pub fn getOverallProgress(_: *const Animation) ?f64 {
    return null;
}

/// Measured: with no effect to commit, Chrome throws NoModificationAllowedError.
pub fn commitStyles(_: *Animation) !void {
    return error.NoModificationAllowed;
}

pub fn getOnCancel(self: *Animation) ?js.Function.Global {
    return self._frame.getEventHandler(self.asEventTarget(), .oncancel);
}

pub fn setOnCancel(self: *Animation, cb: ?js.Function.Global) !void {
    return self._frame.setEventHandler(self.asEventTarget(), .oncancel, cb);
}

pub fn getOnRemove(self: *Animation) ?js.Function.Global {
    return self._frame.getEventHandler(self.asEventTarget(), .onremove);
}

pub fn setOnRemove(self: *Animation, cb: ?js.Function.Global) !void {
    return self._frame.setEventHandler(self.asEventTarget(), .onremove, cb);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Animation);

    pub const Meta = struct {
        pub const name = "Animation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Animation.construct, .{});

    // Chrome's own Object.getOwnPropertyNames(Animation.prototype) order:
    // attributes first, then operations alphabetically, with overallProgress
    // trailing the operations (measured -- it is not in alphabetical position).
    pub const effect = bridge.accessor(Animation.getEffect, Animation.setEffect, .{});
    pub const timeline = bridge.accessor(Animation.getTimeline, Animation.setTimeline, .{});
    pub const startTime = bridge.accessor(Animation.getStartTime, Animation.setStartTime, .{});
    pub const currentTime = bridge.accessor(Animation.getCurrentTime, Animation.setCurrentTime, .{});
    pub const playbackRate = bridge.accessor(Animation.getPlaybackRate, Animation.setPlaybackRate, .{});
    pub const rangeStart = bridge.accessor(Animation.getRangeStart, Animation.setRangeStart, .{});
    pub const rangeEnd = bridge.accessor(Animation.getRangeEnd, Animation.setRangeEnd, .{});
    pub const playState = bridge.accessor(Animation.playState, null, .{});
    pub const replaceState = bridge.accessor(Animation.getReplaceState, null, .{});
    pub const pending = bridge.accessor(Animation.getPending, null, .{});
    pub const id = bridge.accessor(Animation.getId, Animation.setId, .{});
    pub const onfinish = bridge.accessor(Animation.getOnFinish, Animation.setOnFinish, .{});
    pub const oncancel = bridge.accessor(Animation.getOnCancel, Animation.setOnCancel, .{});
    pub const onremove = bridge.accessor(Animation.getOnRemove, Animation.setOnRemove, .{});
    pub const finished = bridge.accessor(Animation.getFinished, null, .{});
    pub const ready = bridge.accessor(Animation.getReady, null, .{});
    pub const cancel = bridge.function(Animation.cancel, .{});
    pub const commitStyles = bridge.function(Animation.commitStyles, .{});
    pub const finish = bridge.function(Animation.finish, .{});
    pub const pause = bridge.function(Animation.pause, .{});
    pub const persist = bridge.function(Animation.persist, .{});
    pub const play = bridge.function(Animation.play, .{});
    pub const reverse = bridge.function(Animation.reverse, .{});
    pub const updatePlaybackRate = bridge.function(Animation.updatePlaybackRate, .{});
    pub const overallProgress = bridge.accessor(Animation.getOverallProgress, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Animation" {
    try testing.htmlRunner("animation/animation.html", .{});
}
