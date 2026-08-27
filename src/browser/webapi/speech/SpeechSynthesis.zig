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
// That wait is Chrome's *browser process* enumerating the platform's voices, and
// it happens once. `voice-warmup-timeline.mjs` drives one headed Chrome through
// several navigations of a page that touches nothing until its own timer fires:
// the first document waits ~700ms after it asks, and every document after it —
// a later navigation, or a child frame created once the parent's list arrived —
// waits 26ms. Two things survive the warmth: the first synchronous call is still
// empty (at `--delay 3000` on a warm process, the ask at 3002ms answers 0 and
// fills at 3028ms), and the ask is still what starts the load (a cold process
// left alone for three seconds has enumerated nothing). So this is not a race
// against page load in either direction: it is a per-browser cost, which is why
// the stamp that remembers it lives on Browser and not here. That run also
// outlives the document that started it: a page that asked and navigated away
// immediately still left the next page warm, which is what the stamp models.
//
// Reproducing that mattered on a station. `antibot-sweep.mjs` drives 29 sites
// through one browser, so a real Chrome reaching a Kasada page is warm from
// whichever earlier site asked first and hands over the list ~26ms in. This
// engine used to restart the full 665ms for every document, which is how a guard
// reading at 555ms got an empty array here and a full one from Chrome.
//
// CreepJS makes that visible. It reads getVoices(), waits 50ms, then gives up
// 300ms later if no voice with `localService` has arrived — so its speech row
// depends on whether anything warmed the TTS service before its own late warm-up
// call, in Chrome exactly as much as here. The row is a race in CreepJS, not a
// property of Chrome, and what puts this engine on the same side of it is the
// *scope* of the wait, not its length. Measured with `creep-speech-row.mjs`,
// each arm one browser, `--warm` visiting one earlier site that asks:
//
//              cold browser            an earlier document asked
//   Chrome     all three blocked       local (180): a158dc36 / remote (19):
//                                      036f6dce / lang (51): c4951b20
//   before     all three blocked       all three blocked
//   after      all three blocked       the same three hashes, byte for byte,
//                                      down to the section hash a8c32496
//
// The middle row is what a per-document wait costs: warm or cold, this engine
// answered `blocked` where a warm Chrome answered with its voices.
//
// speak() has no synthesiser behind it. Rather than doing nothing — which hangs
// any page that waits for `onend` — it fires Chrome's success sequence (start
// then end) on the utterance from a scheduler task, so the page continues.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Browser = @import("../../Browser.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const SpeechSynthesisEvent = @import("SpeechSynthesisEvent.zig");
const SpeechSynthesisUtterance = @import("SpeechSynthesisUtterance.zig");
const SpeechSynthesisVoice = @import("SpeechSynthesisVoice.zig");
const voices = @import("voices.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Execution = js.Execution;

const SpeechSynthesis = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_paused: bool = false,
_speaking: bool = false,

// getVoices() answers empty until the list "arrives". The task that flips this
// is scheduled by the first getVoices() call, matching Chrome, where the list is
// populated lazily on first access rather than at page load.
_voices_ready: bool = false,
_voices_task_queued: bool = false,

// Chrome's measured latency between the first getVoices() and the voice list
// being complete — see the header. Left unrounded because it is the measurement;
// there is nothing to tune it against.
const VOICE_LIST_LATENCY_MS: u32 = 665;

// What the same list costs once the browser already has it: only the round trip
// to ask. 26ms on documents two and three of one browser, 27ms in a child
// document — see the header and Browser.voices_asked_at_micros.
const VOICE_LIST_CACHED_MS: u32 = 26;

// How long this document waits for its list, given what the browser has already
// done about voices. The first ask starts the browser's one enumeration; a later
// one either finds it finished (the round trip alone) or waits out the rest of
// it. Never shorter than the round trip: the list arrives on a task either way.
//
// The mid-run case is the one arm that is reasoned rather than measured — the
// two ends of it are not.
fn browserLatency(browser: *Browser) u32 {
    const now = lp.datetime.microTimestamp(.boot);
    const asked = browser.voices_asked_at_micros orelse {
        browser.voices_asked_at_micros = now;
        return VOICE_LIST_LATENCY_MS;
    };
    const elapsed_ms = (now -| asked) / std.time.us_per_ms;
    if (elapsed_ms >= VOICE_LIST_LATENCY_MS) {
        return VOICE_LIST_CACHED_MS;
    }
    return @max(VOICE_LIST_CACHED_MS, VOICE_LIST_LATENCY_MS - @as(u32, @intCast(elapsed_ms)));
}

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
            const latency = browserLatency(exec.page.session.browser);
            const task = try exec._factory.create(VoicesReadyTask{ .synthesis = self, .exec = exec });
            try exec.js.scheduler.add(task, VoicesReadyTask.run, latency, .{
                .name = "speechSynthesis.voiceschanged",
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
        if (!self.exec.hasDirectListeners(target, "voiceschanged", null)) {
            return null;
        }
        const event = try Event.initTrusted(.wrap("voiceschanged"), .{}, self.exec.page);
        try self.exec.dispatch(target, event, null, .{ .context = "speechSynthesis.voiceschanged" });
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

        try self.dispatch(comptime .wrap("start"), null);
        self.synthesis._speaking = false;
        try self.dispatch(comptime .wrap("end"), null);
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
    pub const onvoiceschanged = bridge.accessor(handlerProperty(SpeechSynthesis, .onvoiceschanged).get, handlerProperty(SpeechSynthesis, .onvoiceschanged).set, .{});
    pub const cancel = bridge.function(SpeechSynthesis.cancel, .{});
    pub const getVoices = bridge.function(SpeechSynthesis.getVoices, .{});
    pub const pause = bridge.function(SpeechSynthesis.pause, .{});
    pub const @"resume" = bridge.function(SpeechSynthesis.@"resume", .{});
    pub const speak = bridge.function(SpeechSynthesis.speak, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: SpeechSynthesis" {
    try testing.htmlRunner("speech.html", .{});
}
