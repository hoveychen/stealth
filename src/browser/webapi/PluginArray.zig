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

// navigator.plugins / navigator.mimeTypes.
//
// Chrome has shipped a hardcoded, non-configurable list here since it dropped
// NPAPI: five aliases for the built-in PDF viewer, carrying two MIME types.
// The list doesn't vary with installed software, so it isn't a fingerprinting
// entropy source — but an *empty* one is, because no real Chrome reports zero
// plugins while `navigator.pdfViewerEnabled` is true.
//
// Every value below was measured from the Chrome 150 install on the reference
// machine, not remembered — see tools/fingerprint/results/reference-chrome-headed.json
// for the names and counts, and the plugin/mimeType shape recorded in
// tools/fingerprint/README.md.
//
// All four types live in this one file because they are a single closed
// cluster: MimeType has to name its owning Plugin and Plugin has to hand out
// MimeTypes, so splitting them would mean a circular import.

const std = @import("std");

const js = @import("../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        PluginArray,
        PluginArray.Iterator,
        Plugin,
        Plugin.Iterator,
        MimeTypeArray,
        MimeTypeArray.Iterator,
        MimeType,
    };
}

const PluginArray = @This();

_pad: bool = false,

// Shared by all five entries and both MIME types.
const pdf_description = "Portable Document Format";
const pdf_filename = "internal-pdf-viewer";
const pdf_suffixes = "pdf";

const plugin_names = [_][]const u8{
    "PDF Viewer",
    "Chrome PDF Viewer",
    "Chromium PDF Viewer",
    "Microsoft Edge PDF Viewer",
    "WebKit built-in PDF",
};

const mime_names = [_][]const u8{ "application/pdf", "text/pdf" };

// The instances are process-wide statics rather than fields on the Navigator
// because Navigator (like most of these API objects) is declared
// `empty_with_no_proto`: the bridge never stores its real address, so a getter
// cannot reach per-Navigator storage. Nothing here is ever written after
// startup. `var` rather than `const` only because the bridge takes non-const
// pointers.
var plugins: [plugin_names.len]Plugin = blk: {
    var out: [plugin_names.len]Plugin = undefined;
    for (&out, 0..) |*p, i| p.* = .{ ._index = i };
    break :blk out;
};

// Each Plugin exposes its own MimeType objects, distinct from the ones on
// navigator.mimeTypes: measured, `navigator.plugins[0][0] !== navigator.mimeTypes[0]`.
var plugin_mimes: [plugin_names.len][mime_names.len]MimeType = blk: {
    var out: [plugin_names.len][mime_names.len]MimeType = undefined;
    for (&out, 0..) |*row, p| {
        for (row, 0..) |*m, t| m.* = .{ ._index = t, ._plugin = p };
    }
    break :blk out;
};

// navigator.mimeTypes' own entries. Measured: both name the *first* plugin as
// their enabledPlugin, and `navigator.mimeTypes[0].enabledPlugin === navigator.plugins[0]`.
var mime_types: [mime_names.len]MimeType = blk: {
    var out: [mime_names.len]MimeType = undefined;
    for (&out, 0..) |*m, t| m.* = .{ ._index = t, ._plugin = 0 };
    break :blk out;
};

pub fn refresh(_: *const PluginArray) void {}

pub fn getLength(_: *const PluginArray) u32 {
    return plugins.len;
}

pub fn getAtIndex(_: *const PluginArray, index: usize) ?*Plugin {
    if (index >= plugins.len) {
        return null;
    }
    return &plugins[index];
}

pub fn getByName(_: *const PluginArray, name: []const u8) ?*Plugin {
    for (&plugins, plugin_names) |*plugin, plugin_name| {
        if (std.mem.eql(u8, name, plugin_name)) {
            return plugin;
        }
    }
    return null;
}

// All three collections are iterable in Chrome. Chrome installs
// Array.prototype.values itself, whereas the bridge's iterator() builds a
// dedicated iterator type — the same shape every other collection here
// (HTMLCollection, NodeList, FileList) already has.
const GenericIterator = @import("collections/iterator.zig").Entry;

pub const Iterator = GenericIterator(struct {
    index: usize = 0,

    pub fn next(self: *@This(), _: *const Execution) ?*Plugin {
        if (self.index >= plugins.len) {
            return null;
        }
        defer self.index += 1;
        return &plugins[self.index];
    }
}, null);

pub fn iterator(_: *PluginArray, exec: *const Execution) !*Iterator {
    return Iterator.init(.{}, exec);
}

const Plugin = struct {
    _index: usize,

    pub fn getName(self: *const Plugin) []const u8 {
        return plugin_names[self._index];
    }

    pub fn getDescription(_: *const Plugin) []const u8 {
        return pdf_description;
    }

    pub fn getFilename(_: *const Plugin) []const u8 {
        return pdf_filename;
    }

    pub fn getLength(_: *const Plugin) u32 {
        return mime_names.len;
    }

    // Chrome builds a fresh wrapper on every read here, so in Chrome
    // `plugins[0][0] !== plugins[0].item(0)`. We return the same instance both
    // times, which the bridge's identity map turns into one stable JS object.
    // Reproducing the churn would mean allocating a MimeType per read with no
    // owner to free it, and no known check looks at this.
    pub fn getAtIndex(self: *const Plugin, index: usize) ?*MimeType {
        if (index >= mime_names.len) {
            return null;
        }
        return &plugin_mimes[self._index][index];
    }

    pub fn getByName(self: *const Plugin, name: []const u8) ?*MimeType {
        for (&plugin_mimes[self._index], mime_names) |*mime, mime_name| {
            if (std.mem.eql(u8, name, mime_name)) {
                return mime;
            }
        }
        return null;
    }

    pub const Iterator = GenericIterator(struct {
        plugin: usize,
        index: usize = 0,

        pub fn next(self: *@This(), _: *const Execution) ?*MimeType {
            if (self.index >= mime_names.len) {
                return null;
            }
            defer self.index += 1;
            return &plugin_mimes[self.plugin][self.index];
        }
    }, null);

    pub fn iterator(self: *Plugin, exec: *const Execution) !*Plugin.Iterator {
        return Plugin.Iterator.init(.{ .plugin = self._index }, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);
        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Plugin.getName, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const length = bridge.accessor(Plugin.getLength, null, .{});
        pub const @"[int]" = bridge.indexedReadWrite(Plugin.getAtIndex, null, null, queryPluginMimeIndex, mimeIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(Plugin.getByName, null, null, pluginMimeNames, queryPluginMimeName, .{ .null_as_undefined = true });
        pub const item = bridge.function(_item, .{});
        pub const namedItem = bridge.function(Plugin.getByName, .{});
        pub const symbol_iterator = bridge.iterator(Plugin.iterator, .{});

        fn _item(self: *const Plugin, index: i32) ?*MimeType {
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index));
        }
    };
};

// navigator.mimeTypes. Stateless like PluginArray: the entries are the statics
// above, so nothing is stored on the instance.
pub const MimeTypeArray = struct {
    _pad: bool = false,

    pub fn getLength(_: *const MimeTypeArray) u32 {
        return mime_types.len;
    }

    pub fn getAtIndex(_: *const MimeTypeArray, index: usize) ?*MimeType {
        if (index >= mime_types.len) {
            return null;
        }
        return &mime_types[index];
    }

    pub fn getByName(_: *const MimeTypeArray, name: []const u8) ?*MimeType {
        for (&mime_types, mime_names) |*mime, mime_name| {
            if (std.mem.eql(u8, name, mime_name)) {
                return mime;
            }
        }
        return null;
    }

    pub const Iterator = GenericIterator(struct {
        index: usize = 0,

        pub fn next(self: *@This(), _: *const Execution) ?*MimeType {
            if (self.index >= mime_types.len) {
                return null;
            }
            defer self.index += 1;
            return &mime_types[self.index];
        }
    }, null);

    pub fn iterator(_: *MimeTypeArray, exec: *const Execution) !*MimeTypeArray.Iterator {
        return MimeTypeArray.Iterator.init(.{}, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeTypeArray);
        pub const Meta = struct {
            pub const name = "MimeTypeArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const length = bridge.accessor(MimeTypeArray.getLength, null, .{});
        pub const @"[int]" = bridge.indexedReadWrite(MimeTypeArray.getAtIndex, null, null, queryMimeTypeIndex, mimeTypeIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(MimeTypeArray.getByName, null, null, mimeTypeNames, queryMimeTypeName, .{ .null_as_undefined = true });
        pub const item = bridge.function(_item, .{});
        pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
        pub const symbol_iterator = bridge.iterator(MimeTypeArray.iterator, .{});

        fn _item(self: *const MimeTypeArray, index: i32) ?*MimeType {
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index));
        }
    };
};

const MimeType = struct {
    _index: usize,
    // Index into `plugins`, not a pointer: a static can't reference its own
    // address while it is being initialized.
    _plugin: usize,

    pub fn getType(self: *const MimeType) []const u8 {
        return mime_names[self._index];
    }

    pub fn getSuffixes(_: *const MimeType) []const u8 {
        return pdf_suffixes;
    }

    pub fn getDescription(_: *const MimeType) []const u8 {
        return pdf_description;
    }

    pub fn getEnabledPlugin(self: *const MimeType) *Plugin {
        return &plugins[self._plugin];
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);
        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(PluginArray);

    pub const Meta = struct {
        pub const name = "PluginArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.accessor(PluginArray.getLength, null, .{});
    pub const item = bridge.function(_item, .{});
    pub const @"[int]" = bridge.indexedReadWrite(PluginArray.getAtIndex, null, null, queryPluginIndex, pluginIndexes, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(PluginArray.getByName, null, null, pluginNameList, queryPluginName, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(PluginArray.iterator, .{});
    pub const namedItem = bridge.function(PluginArray.getByName, .{});
    fn _item(self: *const PluginArray, index: i32) ?*Plugin {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index));
    }
    pub const refresh = bridge.function(PluginArray.refresh, .{});
};

// Own-property enumerators. Chrome reports both the indices and the names as
// own properties of these collections (measured with getOwnPropertyNames), and
// a fingerprint script that walks navigator's collections sees an empty object
// without them.
// Property attributes, measured on Chrome 150: the indices are enumerable,
// configurable and read-only, while the named properties are
// [LegacyUnenumerableNamedProperties] — listed by getOwnPropertyNames but
// skipped by Object.keys, for-in and JSON.stringify. Without the DontEnum,
// `JSON.stringify(navigator.plugins)` would carry the plugin names as keys,
// which is not what any Chrome produces.
fn queryPluginIndex(_: *const PluginArray, idx: u32) !u32 {
    if (idx < plugins.len) {
        return js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn queryPluginName(self: *const PluginArray, name: []const u8) !u32 {
    if (self.getByName(name) != null) {
        return js.v8.DontEnum | js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn queryPluginMimeIndex(_: *const Plugin, idx: u32) !u32 {
    if (idx < mime_names.len) {
        return js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn queryPluginMimeName(self: *const Plugin, name: []const u8) !u32 {
    if (self.getByName(name) != null) {
        return js.v8.DontEnum | js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn queryMimeTypeIndex(_: *const MimeTypeArray, idx: u32) !u32 {
    if (idx < mime_types.len) {
        return js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn queryMimeTypeName(self: *const MimeTypeArray, name: []const u8) !u32 {
    if (self.getByName(name) != null) {
        return js.v8.DontEnum | js.v8.ReadOnly;
    }
    return error.NotHandled;
}

fn indexArray(len: u32, exec: *const Execution) !js.Array {
    var arr = exec.js.local.?.newArray(len);
    for (0..len) |i| {
        _ = try arr.set(@intCast(i), i, .{});
    }
    return arr;
}

fn stringArray(comptime names: []const []const u8, exec: *const Execution) !js.Array {
    var arr = exec.js.local.?.newArray(names.len);
    for (names, 0..) |name, i| {
        _ = try arr.set(@intCast(i), name, .{});
    }
    return arr;
}

fn pluginIndexes(_: *const PluginArray, exec: *const Execution) !js.Array {
    return indexArray(plugins.len, exec);
}

fn pluginNameList(_: *const PluginArray, exec: *const Execution) !js.Array {
    return stringArray(&plugin_names, exec);
}

fn mimeIndexes(_: *const Plugin, exec: *const Execution) !js.Array {
    return indexArray(mime_names.len, exec);
}

fn pluginMimeNames(_: *const Plugin, exec: *const Execution) !js.Array {
    return stringArray(&mime_names, exec);
}

fn mimeTypeIndexes(_: *const MimeTypeArray, exec: *const Execution) !js.Array {
    return indexArray(mime_types.len, exec);
}

fn mimeTypeNames(_: *const MimeTypeArray, exec: *const Execution) !js.Array {
    return stringArray(&mime_names, exec);
}
