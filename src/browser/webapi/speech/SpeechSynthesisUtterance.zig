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

// The thing you hand to speechSynthesis.speak(). Pure state plus the seven
// event handlers Chrome carries on the prototype (measured); the events are
// fired by SpeechSynthesis.speak, not from here.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const SpeechSynthesisVoice = @import("SpeechSynthesisVoice.zig");

const Execution = js.Execution;

const SpeechSynthesisUtterance = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_text: lp.String = .empty,
_lang: lp.String = .empty,
_voice: ?*SpeechSynthesisVoice = null,

// Chrome's defaults, measured: volume, rate and pitch all 1.
_volume: f64 = 1,
_rate: f64 = 1,
_pitch: f64 = 1,

_on_start: ?js.Function.Global = null,
_on_end: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_pause: ?js.Function.Global = null,
_on_resume: ?js.Function.Global = null,
_on_mark: ?js.Function.Global = null,
_on_boundary: ?js.Function.Global = null,

// `text` is optional so the reported arity is 0, matching Chrome's
// SpeechSynthesisUtterance.length (measured); omitting it gives text "".
pub fn init(text: ?lp.String.Global, exec: *Execution) !*SpeechSynthesisUtterance {
    return exec._factory.eventTarget(SpeechSynthesisUtterance{
        ._proto = undefined,
        ._text = if (text) |t| t.str else .empty,
    });
}

pub fn asEventTarget(self: *SpeechSynthesisUtterance) *EventTarget {
    return self._proto;
}

pub fn getText(self: *const SpeechSynthesisUtterance) lp.String {
    return self._text;
}

pub fn setText(self: *SpeechSynthesisUtterance, text: lp.String.Global) void {
    self._text = text.str;
}

pub fn getLang(self: *const SpeechSynthesisUtterance) lp.String {
    return self._lang;
}

pub fn setLang(self: *SpeechSynthesisUtterance, lang: lp.String.Global) void {
    self._lang = lang.str;
}

pub fn getVoice(self: *const SpeechSynthesisUtterance) ?*SpeechSynthesisVoice {
    return self._voice;
}

pub fn setVoice(self: *SpeechSynthesisUtterance, voice: ?*SpeechSynthesisVoice) void {
    self._voice = voice;
}

pub fn getVolume(self: *const SpeechSynthesisUtterance) f64 {
    return self._volume;
}

pub fn setVolume(self: *SpeechSynthesisUtterance, volume: f64) void {
    self._volume = volume;
}

pub fn getRate(self: *const SpeechSynthesisUtterance) f64 {
    return self._rate;
}

pub fn setRate(self: *SpeechSynthesisUtterance, rate: f64) void {
    self._rate = rate;
}

pub fn getPitch(self: *const SpeechSynthesisUtterance) f64 {
    return self._pitch;
}

pub fn setPitch(self: *SpeechSynthesisUtterance, pitch: f64) void {
    self._pitch = pitch;
}

pub fn getOnStart(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_start;
}

pub fn setOnStart(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_start = try persist(self, cb);
}

pub fn getOnEnd(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_end;
}

pub fn setOnEnd(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_end = try persist(self, cb);
}

pub fn getOnError(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_error = try persist(self, cb);
}

pub fn getOnPause(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_pause;
}

pub fn setOnPause(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_pause = try persist(self, cb);
}

pub fn getOnResume(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_resume;
}

pub fn setOnResume(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_resume = try persist(self, cb);
}

pub fn getOnMark(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_mark;
}

pub fn setOnMark(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_mark = try persist(self, cb);
}

pub fn getOnBoundary(self: *const SpeechSynthesisUtterance) ?js.Function.Global {
    return self._on_boundary;
}

pub fn setOnBoundary(self: *SpeechSynthesisUtterance, cb: ?js.Function) !void {
    self._on_boundary = try persist(self, cb);
}

fn persist(self: *SpeechSynthesisUtterance, cb: ?js.Function) !?js.Function.Global {
    const listener = cb orelse return null;
    return try listener.persistWithThis(self);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpeechSynthesisUtterance);

    pub const Meta = struct {
        pub const name = "SpeechSynthesisUtterance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(SpeechSynthesisUtterance.init, .{});

    pub const text = bridge.accessor(SpeechSynthesisUtterance.getText, SpeechSynthesisUtterance.setText, .{});
    pub const lang = bridge.accessor(SpeechSynthesisUtterance.getLang, SpeechSynthesisUtterance.setLang, .{});
    pub const voice = bridge.accessor(SpeechSynthesisUtterance.getVoice, SpeechSynthesisUtterance.setVoice, .{});
    pub const volume = bridge.accessor(SpeechSynthesisUtterance.getVolume, SpeechSynthesisUtterance.setVolume, .{});
    pub const rate = bridge.accessor(SpeechSynthesisUtterance.getRate, SpeechSynthesisUtterance.setRate, .{});
    pub const pitch = bridge.accessor(SpeechSynthesisUtterance.getPitch, SpeechSynthesisUtterance.setPitch, .{});

    pub const onstart = bridge.accessor(SpeechSynthesisUtterance.getOnStart, SpeechSynthesisUtterance.setOnStart, .{});
    pub const onend = bridge.accessor(SpeechSynthesisUtterance.getOnEnd, SpeechSynthesisUtterance.setOnEnd, .{});
    pub const onerror = bridge.accessor(SpeechSynthesisUtterance.getOnError, SpeechSynthesisUtterance.setOnError, .{});
    pub const onpause = bridge.accessor(SpeechSynthesisUtterance.getOnPause, SpeechSynthesisUtterance.setOnPause, .{});
    pub const onresume = bridge.accessor(SpeechSynthesisUtterance.getOnResume, SpeechSynthesisUtterance.setOnResume, .{});
    pub const onmark = bridge.accessor(SpeechSynthesisUtterance.getOnMark, SpeechSynthesisUtterance.setOnMark, .{});
    pub const onboundary = bridge.accessor(SpeechSynthesisUtterance.getOnBoundary, SpeechSynthesisUtterance.setOnBoundary, .{});
};
