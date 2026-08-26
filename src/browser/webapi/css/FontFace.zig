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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

const FontFace = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_family: []const u8,

// The eight font descriptors, all `attribute CSSOMString` and all read-write.
// They were data properties with the class-wide default baked in, which made
// them a constant shared by every FontFace and -- the reason they are here --
// data properties where Chrome has accessors, which is what a bot check reads
// (see src/browser/tests/descriptor_kind.html). The defaults below are Chrome's,
// measured off `new FontFace('D', 'local(Arial)')`.
_style: []const u8 = "normal",
_weight: []const u8 = "normal",
_stretch: []const u8 = "normal",
_unicode_range: []const u8 = "U+0-10FFFF",
_variant: []const u8 = "normal",
_feature_settings: []const u8 = "normal",
_display: []const u8 = "auto",
// Five more of the same, added later to the IDL and so declared after `load`
// on Chrome's prototype. Defaults measured off `new FontFace('D',
// 'local(Arial)')`: every override is "normal" and the size adjustment is
// "100%".
_ascent_override: []const u8 = "normal",
_descent_override: []const u8 = "normal",
_line_gap_override: []const u8 = "normal",
_size_adjust: []const u8 = "100%",
_variation_settings: []const u8 = "normal",

/// The descriptor dictionary the constructor takes, which Chrome applies to
/// the face it builds: `new FontFace('F', src, {ascentOverride: '90%'})` reads
/// back "90%" (measured on Chrome 151). Every field is optional and an absent
/// one leaves the default alone.
pub const Descriptors = struct {
    style: ?[]const u8 = null,
    weight: ?[]const u8 = null,
    stretch: ?[]const u8 = null,
    unicodeRange: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    featureSettings: ?[]const u8 = null,
    display: ?[]const u8 = null,
    ascentOverride: ?[]const u8 = null,
    descentOverride: ?[]const u8 = null,
    lineGapOverride: ?[]const u8 = null,
    sizeAdjust: ?[]const u8 = null,
    variationSettings: ?[]const u8 = null,
};

pub fn init(family: []const u8, source: []const u8, descriptors_: ?Descriptors, exec: *const Execution) !*FontFace {
    _ = source;

    const arena = try exec.getArena(.tiny, "FontFace");
    errdefer arena.release();

    const self = try arena.create(FontFace);
    self.* = .{
        ._arena = arena,
        ._family = try arena.dupe(u8, family),
    };

    if (descriptors_) |descriptors| {
        inline for (.{
            .{ "style", &self._style },
            .{ "weight", &self._weight },
            .{ "stretch", &self._stretch },
            .{ "unicodeRange", &self._unicode_range },
            .{ "variant", &self._variant },
            .{ "featureSettings", &self._feature_settings },
            .{ "display", &self._display },
            .{ "ascentOverride", &self._ascent_override },
            .{ "descentOverride", &self._descent_override },
            .{ "lineGapOverride", &self._line_gap_override },
            .{ "sizeAdjust", &self._size_adjust },
            .{ "variationSettings", &self._variation_settings },
        }) |pair| {
            if (@field(descriptors, pair[0])) |value| {
                pair[1].* = try arena.dupe(u8, value);
            }
        }
    }
    return self;
}

pub fn getAscentOverride(self: *const FontFace) []const u8 {
    return self._ascent_override;
}
pub fn setAscentOverride(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._ascent_override, value);
}
pub fn getDescentOverride(self: *const FontFace) []const u8 {
    return self._descent_override;
}
pub fn setDescentOverride(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._descent_override, value);
}
pub fn getLineGapOverride(self: *const FontFace) []const u8 {
    return self._line_gap_override;
}
pub fn setLineGapOverride(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._line_gap_override, value);
}
pub fn getSizeAdjust(self: *const FontFace) []const u8 {
    return self._size_adjust;
}
pub fn setSizeAdjust(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._size_adjust, value);
}
pub fn getVariationSettings(self: *const FontFace) []const u8 {
    return self._variation_settings;
}
pub fn setVariationSettings(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._variation_settings, value);
}

pub fn deinit(self: *FontFace, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *FontFace, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFace) void {
    self._rc.acquire();
}

pub fn getFamily(self: *const FontFace) []const u8 {
    return self._family;
}

/// Every descriptor is stored verbatim on this instance's own arena, which lives
/// as long as the FontFace does.
///
/// Chrome *parses* the assignment and throws a SyntaxError DOMException on a
/// value the descriptor's grammar rejects -- measured, `ff.style = 'garbage'`
/// answers "Failed to set 'garbage' as a property value." There is no CSS font
/// descriptor parser here, so an unparsable value sticks instead of throwing.
/// That is a known gap and a smaller one than the descriptor kind this fixes: it
/// takes a detector that assigns deliberate garbage to see it, where the kind is
/// visible to anything that reads `getOwnPropertyDescriptor`.
fn setDescriptor(self: *FontFace, field: *[]const u8, value: []const u8) !void {
    field.* = try self._arena.allocator().dupe(u8, value);
}

pub fn setFamily(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._family, value);
}

pub fn getStyle(self: *const FontFace) []const u8 {
    return self._style;
}

pub fn setStyle(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._style, value);
}

pub fn getWeight(self: *const FontFace) []const u8 {
    return self._weight;
}

pub fn setWeight(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._weight, value);
}

pub fn getStretch(self: *const FontFace) []const u8 {
    return self._stretch;
}

pub fn setStretch(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._stretch, value);
}

pub fn getUnicodeRange(self: *const FontFace) []const u8 {
    return self._unicode_range;
}

pub fn setUnicodeRange(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._unicode_range, value);
}

pub fn getVariant(self: *const FontFace) []const u8 {
    return self._variant;
}

pub fn setVariant(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._variant, value);
}

pub fn getFeatureSettings(self: *const FontFace) []const u8 {
    return self._feature_settings;
}

pub fn setFeatureSettings(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._feature_settings, value);
}

pub fn getDisplay(self: *const FontFace) []const u8 {
    return self._display;
}

pub fn setDisplay(self: *FontFace, value: []const u8) !void {
    return self.setDescriptor(&self._display, value);
}

// Readonly, and "loaded" because there is no font loading to be partway
// through: `load()` and `loaded` both resolve immediately. Chrome answers
// "unloaded" for a freshly constructed FontFace, which is a value difference and
// not this change's business -- only the kind moves here.
pub fn getStatus(_: *const FontFace) []const u8 {
    return "loaded";
}

// load() - resolves immediately; headless browser has no real font loading.
pub fn load(_: *FontFace, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

// loaded - returns an already-resolved Promise.
pub fn getLoaded(_: *FontFace, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFace);

    pub const Meta = struct {
        pub const name = "FontFace";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FontFace.init, .{});

    // Chrome's order: the eight original descriptors, the four override ones,
    // then status/loaded/load -- and `variationSettings` last, after `load`,
    // because it joined the IDL through a later partial interface.
    pub const family = bridge.accessor(FontFace.getFamily, FontFace.setFamily, .{});
    pub const style = bridge.accessor(FontFace.getStyle, FontFace.setStyle, .{});
    pub const weight = bridge.accessor(FontFace.getWeight, FontFace.setWeight, .{});
    pub const stretch = bridge.accessor(FontFace.getStretch, FontFace.setStretch, .{});
    pub const unicodeRange = bridge.accessor(FontFace.getUnicodeRange, FontFace.setUnicodeRange, .{});
    pub const variant = bridge.accessor(FontFace.getVariant, FontFace.setVariant, .{});
    pub const featureSettings = bridge.accessor(FontFace.getFeatureSettings, FontFace.setFeatureSettings, .{});
    pub const display = bridge.accessor(FontFace.getDisplay, FontFace.setDisplay, .{});
    pub const ascentOverride = bridge.accessor(FontFace.getAscentOverride, FontFace.setAscentOverride, .{});
    pub const descentOverride = bridge.accessor(FontFace.getDescentOverride, FontFace.setDescentOverride, .{});
    pub const lineGapOverride = bridge.accessor(FontFace.getLineGapOverride, FontFace.setLineGapOverride, .{});
    pub const sizeAdjust = bridge.accessor(FontFace.getSizeAdjust, FontFace.setSizeAdjust, .{});
    pub const status = bridge.accessor(FontFace.getStatus, null, .{});
    pub const loaded = bridge.accessor(FontFace.getLoaded, null, .{});
    pub const load = bridge.function(FontFace.load, .{});
    pub const variationSettings = bridge.accessor(FontFace.getVariationSettings, FontFace.setVariationSettings, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFace" {
    try testing.htmlRunner("css/font_face.html", .{});
}
