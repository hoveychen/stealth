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

// window.speechSynthesis. It was absent entirely, which iphey reports as an
// `alert()` reading "ReferenceError: speechSynthesis is not defined" and CreepJS
// renders as a blocked speech section.
//
// getVoices() reproduces Chrome's timing as well as its values: the first
// synchronous call returns an empty array, the measured macOS list (199 entries
// — voices.zig) arrives ~665ms later, and `voiceschanged` fires then.
//
// The latency is measured, not chosen. Polling a headed Chrome every 25ms from
// first access, three runs: the first read is always empty, `voiceschanged`
// fires at 661/662/664ms and the list is complete at 668/675/675ms.
//
// Reproducing the latency rather than filling on the next task keeps *both*
// observable windows right: the one where Chrome answers empty, and the one where
// it answers the full list.
//
// CreepJS makes that visible. It reads getVoices(), waits 50ms, then gives up
// 300ms later if no voice with `localService` has arrived — so its speech row
// depends on whether anything warmed the TTS service before its own late warm-up
// call, in Chrome exactly as much as here. With a getVoices() injected at document
// start, a headed Chrome renders `local (180): a158dc36 / remote (19): 036f6dce /
// lang (51): c4951b20`, which is byte for byte what this engine renders. With
// nothing warming it — a plain sweep, headed or headless, cold profile or warm —
// the same Chrome renders all three blocked. The row is a race in CreepJS, not a
// property of Chrome, and matching Chrome's latency is what makes this engine sit
// on the same side of it.
//
// speak() has no synthesiser behind it. Rather than doing nothing — which hangs
// any page that waits for `onend` — it fires Chrome's success sequence (start
// then end) on the utterance from a scheduler task, so the page continues.

const std = @import("std");

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const SpeechSynthesisEvent = @import("SpeechSynthesisEvent.zig");
const SpeechSynthesisUtterance = @import("SpeechSynthesisUtterance.zig");
const SpeechSynthesisVoice = @import("SpeechSynthesisVoice.zig");
const voices = @import("voices.zig");

const Execution = js.Execution;

const SpeechSynthesis = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_paused: bool = false,
_speaking: bool = false,
_on_voices_changed: ?js.Function.Global = null,

// getVoices() answers empty until the list "arrives". The task that flips this
// is scheduled by the first getVoices() call, matching Chrome, where the list is
// populated lazily on first access rather than at page load.
_voices_ready: bool = false,
_voices_task_queued: bool = false,

// Chrome's measured latency between the first getVoices() and the voice list
// being complete — see the header. Left unrounded because it is the measurement;
// there is nothing to tune it against.
const VOICE_LIST_LATENCY_MS: u32 = 665;

pub fn asEventTarget(self: *SpeechSynthesis) *EventTarget {
    return self._proto;
}

// Nothing is ever queued behind the current utterance: speak() drains it on the
// next task, so `pending` is the false Chrome reports for an idle synthesiser.
pub fn getPending(_: *const SpeechSynthesis) bool {
    return false;
}

pub fn getSpeaking(self: *const SpeechSynthesis) bool {
    return self._speaking;
}

pub fn getPaused(self: *const SpeechSynthesis) bool {
    return self._paused;
}

pub fn getVoices(self: *SpeechSynthesis, exec: *Execution) ![]*SpeechSynthesisVoice {
    if (self._voices_ready == false) {
        if (self._voices_task_queued == false) {
            self._voices_task_queued = true;
            const task = try exec._factory.create(VoicesReadyTask{ .synthesis = self, .exec = exec });
            try exec.js.scheduler.add(task, VoicesReadyTask.run, VOICE_LIST_LATENCY_MS, .{
                .name = "speechSynthesis.voiceschanged",
                .low_priority = false,
                .finalizer = VoicesReadyTask.cancelled,
            });
        }
        return &.{};
    }

    const frame = exec.js.global.frame;
    if (frame.window._voices) |cached| {
        return cached;
    }

    // One allocation pass, cached on the window: getVoices() hands back the same
    // objects every call in Chrome, and scripts compare them by identity.
    const factory = exec._factory;
    const list = try factory._arena.alloc(*SpeechSynthesisVoice, voices.all.len);
    for (voices.all, list) |voice, *slot| {
        slot.* = try factory.create(voice);
    }
    frame.window._voices = list;
    return list;
}

// Flips getVoices() from empty to the full list and fires voiceschanged, which is
// the event a page waits on when its first read came back empty.
const VoicesReadyTask = struct {
    synthesis: *SpeechSynthesis,
    exec: *Execution,

    fn cancelled(ctx: *anyopaque) void {
        const self: *VoicesReadyTask = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *VoicesReadyTask = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        const synthesis = self.synthesis;
        synthesis._voices_ready = true;

        const target = synthesis.asEventTarget();
        if (!self.exec.hasDirectListeners(target, "voiceschanged", synthesis._on_voices_changed)) {
            return null;
        }
        const event = try Event.initTrusted(.wrap("voiceschanged"), .{}, self.exec.page);
        try self.exec.dispatch(target, event, synthesis._on_voices_changed, .{ .context = "speechSynthesis.voiceschanged" });
        return null;
    }
};

pub fn speak(self: *SpeechSynthesis, utterance: *SpeechSynthesisUtterance, exec: *Execution) !void {
    self._speaking = true;

    const task = try exec._factory.create(SpeakTask{
        .synthesis = self,
        .utterance = utterance,
        .exec = exec,
    });
    try exec.js.scheduler.add(task, SpeakTask.run, 0, .{
        .name = "SpeechSynthesis.speak",
        .low_priority = false,
        .finalizer = SpeakTask.cancelled,
    });
}

pub fn cancel(self: *SpeechSynthesis) void {
    self._speaking = false;
}

pub fn pause(self: *SpeechSynthesis) void {
    self._paused = true;
}

pub fn @"resume"(self: *SpeechSynthesis) void {
    self._paused = false;
}

pub fn getOnVoicesChanged(self: *const SpeechSynthesis) ?js.Function.Global {
    return self._on_voices_changed;
}

pub fn setOnVoicesChanged(self: *SpeechSynthesis, cb: ?js.Function) !void {
    if (cb) |listener| {
        self._on_voices_changed = try listener.persistWithThis(self);
    } else {
        self._on_voices_changed = null;
    }
}

// Delivers Chrome's start-then-end pair for one utterance. `cancel()` between
// the speak() call and this task running suppresses both, like Chrome.
const SpeakTask = struct {
    synthesis: *SpeechSynthesis,
    utterance: *SpeechSynthesisUtterance,
    exec: *Execution,

    fn cancelled(ctx: *anyopaque) void {
        const self: *SpeakTask = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *SpeakTask = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        if (self.synthesis._speaking == false) {
            return null;
        }

        const exec = self.exec;
        const utterance = self.utterance;
        try self.dispatch(comptime .wrap("start"), utterance._on_start);
        self.synthesis._speaking = false;
        try self.dispatch(comptime .wrap("end"), utterance._on_end);
        _ = exec;
        return null;
    }

    fn dispatch(self: *SpeakTask, comptime typ: @import("lightpanda").String, handler: ?js.Function.Global) !void {
        const event = (try SpeechSynthesisEvent.initTrusted(
            typ,
            .{ .utterance = self.utterance },
            self.exec.page,
        )).asEvent();
        return self.exec.dispatch(self.utterance.asEventTarget(), event, handler, .{ .context = "speechSynthesis.speak" });
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpeechSynthesis);

    pub const Meta = struct {
        pub const name = "SpeechSynthesis";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const pending = bridge.accessor(SpeechSynthesis.getPending, null, .{});
    pub const speaking = bridge.accessor(SpeechSynthesis.getSpeaking, null, .{});
    pub const paused = bridge.accessor(SpeechSynthesis.getPaused, null, .{});
    pub const onvoiceschanged = bridge.accessor(SpeechSynthesis.getOnVoicesChanged, SpeechSynthesis.setOnVoicesChanged, .{});

    pub const getVoices = bridge.function(SpeechSynthesis.getVoices, .{});
    pub const speak = bridge.function(SpeechSynthesis.speak, .{});
    pub const cancel = bridge.function(SpeechSynthesis.cancel, .{});
    pub const pause = bridge.function(SpeechSynthesis.pause, .{});
    pub const @"resume" = bridge.function(SpeechSynthesis.@"resume", .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: SpeechSynthesis" {
    try testing.htmlRunner("speech.html", .{});
}
