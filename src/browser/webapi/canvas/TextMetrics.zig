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

// https://developer.mozilla.org/en-US/docs/Web/API/TextMetrics
//
// The ten read-only attributes Chrome exposes, in Chrome's order. The numbers
// come from text_measure.measure; this type only carries them across the
// bridge.

const std = @import("std");

const js = @import("../../js/js.zig");
const text_measure = @import("../../text_measure.zig");

const TextMetrics = @This();

_metrics: text_measure.Metrics,

pub fn getWidth(self: *const TextMetrics) f64 {
    return self._metrics.width;
}

pub fn getActualBoundingBoxLeft(self: *const TextMetrics) f64 {
    return self._metrics.actualBoundingBoxLeft;
}

pub fn getActualBoundingBoxRight(self: *const TextMetrics) f64 {
    return self._metrics.actualBoundingBoxRight;
}

pub fn getFontBoundingBoxAscent(self: *const TextMetrics) f64 {
    return self._metrics.fontBoundingBoxAscent;
}

pub fn getFontBoundingBoxDescent(self: *const TextMetrics) f64 {
    return self._metrics.fontBoundingBoxDescent;
}

pub fn getActualBoundingBoxAscent(self: *const TextMetrics) f64 {
    return self._metrics.actualBoundingBoxAscent;
}

pub fn getActualBoundingBoxDescent(self: *const TextMetrics) f64 {
    return self._metrics.actualBoundingBoxDescent;
}

pub fn getHangingBaseline(self: *const TextMetrics) f64 {
    return self._metrics.hangingBaseline;
}

pub fn getAlphabeticBaseline(self: *const TextMetrics) f64 {
    return self._metrics.alphabeticBaseline;
}

pub fn getIdeographicBaseline(self: *const TextMetrics) f64 {
    return self._metrics.ideographicBaseline;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextMetrics);

    pub const Meta = struct {
        pub const name = "TextMetrics";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(TextMetrics.getWidth, null, .{});
    pub const actualBoundingBoxLeft = bridge.accessor(TextMetrics.getActualBoundingBoxLeft, null, .{});
    pub const actualBoundingBoxRight = bridge.accessor(TextMetrics.getActualBoundingBoxRight, null, .{});
    pub const fontBoundingBoxAscent = bridge.accessor(TextMetrics.getFontBoundingBoxAscent, null, .{});
    pub const fontBoundingBoxDescent = bridge.accessor(TextMetrics.getFontBoundingBoxDescent, null, .{});
    pub const actualBoundingBoxAscent = bridge.accessor(TextMetrics.getActualBoundingBoxAscent, null, .{});
    pub const actualBoundingBoxDescent = bridge.accessor(TextMetrics.getActualBoundingBoxDescent, null, .{});
    pub const hangingBaseline = bridge.accessor(TextMetrics.getHangingBaseline, null, .{});
    pub const alphabeticBaseline = bridge.accessor(TextMetrics.getAlphabeticBaseline, null, .{});
    pub const ideographicBaseline = bridge.accessor(TextMetrics.getIdeographicBaseline, null, .{});
};
