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
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

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

    pub const onstart = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onstart).get, handlerProperty(SpeechSynthesisUtterance, .onstart).set, .{});
    pub const onend = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onend).get, handlerProperty(SpeechSynthesisUtterance, .onend).set, .{});
    pub const onerror = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onerror).get, handlerProperty(SpeechSynthesisUtterance, .onerror).set, .{});
    pub const onpause = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onpause).get, handlerProperty(SpeechSynthesisUtterance, .onpause).set, .{});
    pub const onresume = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onresume).get, handlerProperty(SpeechSynthesisUtterance, .onresume).set, .{});
    pub const onmark = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onmark).get, handlerProperty(SpeechSynthesisUtterance, .onmark).set, .{});
    pub const onboundary = bridge.accessor(handlerProperty(SpeechSynthesisUtterance, .onboundary).get, handlerProperty(SpeechSynthesisUtterance, .onboundary).set, .{});
};
