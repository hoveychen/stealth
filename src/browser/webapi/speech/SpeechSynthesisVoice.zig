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

// One entry of speechSynthesis.getVoices(). The table itself is measured, in
// voices.zig — see the generator note there.

const js = @import("../../js/js.zig");

const SpeechSynthesisVoice = @This();

_voice_uri: []const u8,
_name: []const u8,
_lang: []const u8,
_local_service: bool,
_default: bool,

pub fn getVoiceURI(self: *const SpeechSynthesisVoice) []const u8 {
    return self._voice_uri;
}

pub fn getName(self: *const SpeechSynthesisVoice) []const u8 {
    return self._name;
}

pub fn getLang(self: *const SpeechSynthesisVoice) []const u8 {
    return self._lang;
}

pub fn getLocalService(self: *const SpeechSynthesisVoice) bool {
    return self._local_service;
}

pub fn getDefault(self: *const SpeechSynthesisVoice) bool {
    return self._default;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpeechSynthesisVoice);

    pub const Meta = struct {
        pub const name = "SpeechSynthesisVoice";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const voiceURI = bridge.accessor(SpeechSynthesisVoice.getVoiceURI, null, .{});
    pub const name = bridge.accessor(SpeechSynthesisVoice.getName, null, .{});
    pub const lang = bridge.accessor(SpeechSynthesisVoice.getLang, null, .{});
    pub const localService = bridge.accessor(SpeechSynthesisVoice.getLocalService, null, .{});
    pub const default = bridge.accessor(SpeechSynthesisVoice.getDefault, null, .{});
};
